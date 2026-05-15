# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# Author: The Establishment
# Date: 2026-04-08
# FileRole: Scanner
#Requires -Version 5.1
<#
.SYNOPSIS
    Full Workspace Dependency Scan — static mode, no engine required.
.DESCRIPTION
    Runs all 6 dependency scan phases independently, each in its own try/catch.
    A phase failure is trapped, logged, and a BUGS2FIX pipeline ToDo is created,
    but does NOT stop subsequent phases. All phases are attempted.

    Phases:  1. folders   2. modules   3. scripts
             4. configs   5. urls_ips  6. dns_resolution

    Writes results to:
      - logs/scan-progress.json          (live progress, same format as engine scan)
      - checkpoints/dependency-scan-checkpoint.json  (merged with existing data)
      - ~REPORTS/static-scan-{ts}.json  (full audit report)
    Pushes phase failures as BUGS2FIX items to config/cron-aiathon-pipeline.json.

.PARAMETER WorkspacePath
    Root of workspace. Defaults to parent of $PSScriptRoot.
.PARAMETER PipelinePath
    Override path to cron-aiathon-pipeline.json.
.PARAMETER SkipDns
    Skip DNS resolution phase (fast mode).
.PARAMETER Phases
    Comma-separated list of phases to run. Default: all 6.
.EXAMPLE
    .\scripts\Invoke-StaticWorkspaceScan.ps1
    .\scripts\Invoke-StaticWorkspaceScan.ps1 -SkipDns
    .\scripts\Invoke-StaticWorkspaceScan.ps1 -Phases 'folders,modules,scripts'
#>

[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [string]$PipelinePath,
    [switch]$SkipDns,
    [string]$Phases = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ─── Paths ────────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path $PSScriptRoot -Parent
}
$WorkspacePath = [System.IO.Path]::GetFullPath($WorkspacePath)
$LogsDir      = Join-Path $WorkspacePath 'logs'
$ReportsDir   = Join-Path $WorkspacePath '~REPORTS'
$CheckpointDir= Join-Path $WorkspacePath 'checkpoints'
$ProgressFile = Join-Path $LogsDir 'scan-progress.json'
$ActivityFile = Join-Path $LogsDir 'scan-activity.log'
$CheckpointFile = Join-Path $CheckpointDir 'dependency-scan-checkpoint.json'
$Timestamp    = Get-Date -Format 'yyyyMMdd-HHmm'
$ReportFile   = Join-Path $ReportsDir "static-scan-$Timestamp.json"
if ([string]::IsNullOrWhiteSpace($PipelinePath)) {
    $PipelinePath = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-pipeline.json'
}

# Ensure output dirs exist
foreach ($d in @($LogsDir, $ReportsDir, $CheckpointDir)) {
    if (-not (Test-Path $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
}

# Exclusion list
$ExcludedFolders = @('.git','.history','.venv','.venv-pygame312','archive','todo',
                     'temp','~DOWNLOADS','~REPORTS','checkpoints','node_modules',
                     'pki','Report','secdump','remediation-backups','__pycache__',
                     'crash-quarantine','crash-dumps')

$AllPhases = @('folders','modules','scripts','configs','urls_ips','dns_resolution')
$RunPhases = if (-not [string]::IsNullOrWhiteSpace($Phases)) {
    $Phases -split ',' | ForEach-Object { $_.Trim().ToLower() }
} else {
    $AllPhases
}
if ($SkipDns) { $RunPhases = $RunPhases | Where-Object { $_ -ne 'dns_resolution' } }

# ─── Progress state ───────────────────────────────────────────────────────────
$progress = [ordered]@{
    status          = 'running'
    mode            = 'Static'
    startedAt       = (Get-Date -Format 'o')
    finishedAt      = $null
    error           = $null
    totalPhases     = @($RunPhases).Count
    completedPhases = 0
    currentPhase    = $null
    phasesStatus    = [ordered]@{}
    activity        = @()
}
foreach ($ph in $AllPhases) { $progress.phasesStatus[$ph] = 'pending' }
foreach ($ph in $AllPhases) {
    if ($RunPhases -notcontains $ph) { $progress.phasesStatus[$ph] = 'skipped' }
}

function Write-ScanProgress {
    $json = $progress | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $ProgressFile -Value $json -Encoding UTF8
}

function Add-ScanActivity {
    param([string]$Phase, [string]$Msg, [string]$Level = 'INFO')
    $evt = [ordered]@{
        timestamp = (Get-Date -Format 'o')
        phase     = $Phase
        level     = $Level
        message   = $Msg
    }
    $progress.activity += $evt
    if (@($progress.activity).Count -gt 120) {
        $progress.activity = @($progress.activity | Select-Object -Last 120)
    }
    try { Add-Content -LiteralPath $ActivityFile -Value ($evt | ConvertTo-Json -Compress) -Encoding UTF8 } catch { <# non-fatal #> }
    Write-ScanProgress
}

function Write-PhaseLog {
    param([string]$Phase, [string]$Msg, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$ts][$Phase][$Level] $Msg"
    Add-ScanActivity -Phase $Phase -Msg $Msg -Level $Level
}

function Test-MapHasKey {
    param(
        [Parameter(Mandatory = $true)]$Map,
        [Parameter(Mandatory = $true)][string]$Key
    )
    if ($null -eq $Map) { return $false }
    if ($Map -is [System.Collections.Specialized.OrderedDictionary]) { return $Map.Contains($Key) }
    if ($Map -is [System.Collections.IDictionary]) { return $Map.Contains($Key) }
    return @($Map.PSObject.Properties.Name | Where-Object { $_ -eq $Key }).Count -gt 0
}

Write-ScanProgress

# ─── Checkpoint helpers ───────────────────────────────────────────────────────
function Load-Checkpoint {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    if (Test-Path -LiteralPath $CheckpointFile) {
        try {
            $raw = Get-Content -LiteralPath $CheckpointFile -Raw -Encoding UTF8
            if (-not [string]::IsNullOrEmpty($raw)) {
                return $raw | ConvertFrom-Json
            }
        } catch { <# non-fatal #> }
    }
    return [pscustomobject]@{ phases = [pscustomobject]@{}; generated = $null }
}

function Save-Checkpoint {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param($Data)
    try {
        $json = $Data | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $CheckpointFile -Value $json -Encoding UTF8
    } catch { Write-PhaseLog 'checkpoint' "Failed to write checkpoint: $_" 'WARN' }
}

$checkpoint = Load-Checkpoint

# ─── Pipeline ToDo helpers ────────────────────────────────────────────────────
$bugsToPush = [System.Collections.ArrayList]@()
$subFailures = [System.Collections.ArrayList]@()

function Register-SubFailure {
    param([string]$Phase, [string]$Target, [string]$ErrorMsg)
    $null = $subFailures.Add([pscustomobject]@{
        phase   = $Phase
        target  = $Target
        error   = $ErrorMsg
        at      = (Get-Date -Format 'o')
    })
}

function New-ScanPhaseBug {
    param([string]$Phase, [string]$ErrorMsg)
    $now  = Get-Date -Format 'o'
    $hash = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Phase-$ErrorMsg")
    $hb   = $hash.ComputeHash($bytes); $hash.Dispose()
    $sid  = ([System.BitConverter]::ToString($hb[0..3]) -replace '-','').ToLower()
    return [ordered]@{
        id              = "Bug-SCAN-$Timestamp-$sid"
        type            = 'Bug'
        status          = 'OPEN'
        priority        = 'HIGH'
        category        = 'scan-phase-failure'
        title           = "[SCAN FAIL] Phase '$Phase' failed in static scan"
        description     = "Static workspace scan phase '$Phase' failed: $ErrorMsg"
        affectedFiles   = @()
        source          = 'Invoke-StaticWorkspaceScan'
        created         = $now
        modified        = $now
        completedAt     = $null
        linkedFeatures  = @()
        linkedBugs      = @()
        tags            = @('scan','phase-failure', $Phase)
        notes           = "Detected during static scan run at $Timestamp. Report: $ReportFile"
        sessionModCount = 0
        parentId        = ''
        executionAgent  = ''
    }
}

# ─── Phase results accumulator ────────────────────────────────────────────────
$phaseResults = [ordered]@{}

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 1: Folders
# ══════════════════════════════════════════════════════════════════════════════
if ($RunPhases -contains 'folders') {
    $phaseStart = Get-Date
    $progress.currentPhase = 'folders'; $progress.phasesStatus['folders'] = 'running'; Write-ScanProgress
    Write-PhaseLog 'folders' 'Starting folder enumeration'
    try {
        $allFolders = @(Get-ChildItem -Path $WorkspacePath -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = $_.FullName.Substring($WorkspacePath.Length).TrimStart('\/')
                -not ($rel -split '[\\/]' | Where-Object { $ExcludedFolders -contains $_ })
            })
        $folderCount = @($allFolders).Count
        Write-PhaseLog 'folders' "Found $folderCount folders" 'INFO'
        $phaseResults['folders'] = @{ count = $folderCount; items = @($allFolders | ForEach-Object { $_.FullName.Substring($WorkspacePath.Length).TrimStart('\/') }) }
        $progress.phasesStatus['folders'] = 'done'; $progress.completedPhases++
        if (-not $checkpoint.phases.PSObject.Properties.Name -contains 'folders') {
            $checkpoint.phases | Add-Member -MemberType NoteProperty -Name 'folders' -Value @{} -Force
        }
        $checkpoint.phases.folders = @{ count = $folderCount; completedAt = (Get-Date -Format 'o'); durationMs = [int]((Get-Date) - $phaseStart).TotalMilliseconds; status = 'done' }
    } catch {
        $errMsg = "$_"
        Write-PhaseLog 'folders' "FAILED: $errMsg" 'ERROR'
        $progress.phasesStatus['folders'] = 'error'
        $phaseResults['folders'] = @{ error = $errMsg }
        $null = $bugsToPush.Add((New-ScanPhaseBug -Phase 'folders' -ErrorMsg $errMsg))
    }
    Write-ScanProgress
}

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 2: Modules
# ══════════════════════════════════════════════════════════════════════════════
if ($RunPhases -contains 'modules') {
    $phaseStart = Get-Date
    $progress.currentPhase = 'modules'; $progress.phasesStatus['modules'] = 'running'; Write-ScanProgress
    Write-PhaseLog 'modules' 'Scanning module files (.psm1/.psd1)'
    try {
        $mods = @(Get-ChildItem -Path $WorkspacePath -Recurse -Include '*.psm1','*.psd1' -File -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = $_.FullName.Substring($WorkspacePath.Length).TrimStart('\/')
                -not ($rel -split '[\\/]' | Where-Object { $ExcludedFolders -contains $_ })
            })
        $funcCount = 0; $modItems = [System.Collections.ArrayList]@()
        foreach ($mod in $mods) {
            $rel = $mod.FullName.Substring($WorkspacePath.Length).TrimStart('\/')
            $functions = @()
            try {
                $modContent = Get-Content -LiteralPath $mod.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
                $functions  = @($modContent | Select-String -Pattern '^\s*function\s+([A-Za-z][\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
                $funcCount += @($functions).Count
            } catch {
                Register-SubFailure -Phase 'modules' -Target $rel -ErrorMsg $_.Exception.Message
            }
            $null = $modItems.Add([pscustomobject]@{ path = $rel; name = $mod.BaseName; functions = $functions; sizeKB = [Math]::Round($mod.Length/1KB,1) })
        }
        Write-PhaseLog 'modules' "Found $(@($mods).Count) module files, $funcCount exported functions" 'INFO'
        $phaseResults['modules'] = @{ count = @($mods).Count; functionCount = $funcCount; items = @($modItems) }
        $progress.phasesStatus['modules'] = 'done'; $progress.completedPhases++
        $checkpoint.phases | Add-Member -MemberType NoteProperty -Name 'modules' -Value @{ count = @($mods).Count; functionCount = $funcCount; completedAt = (Get-Date -Format 'o'); durationMs = [int]((Get-Date) - $phaseStart).TotalMilliseconds; status = 'done' } -Force
    } catch {
        $errMsg = "$_"
        Write-PhaseLog 'modules' "FAILED: $errMsg" 'ERROR'
        $progress.phasesStatus['modules'] = 'error'
        $phaseResults['modules'] = @{ error = $errMsg }
        $null = $bugsToPush.Add((New-ScanPhaseBug -Phase 'modules' -ErrorMsg $errMsg))
    }
    Write-ScanProgress
}

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 3: Scripts
# ══════════════════════════════════════════════════════════════════════════════
if ($RunPhases -contains 'scripts') {
    $phaseStart = Get-Date
    $progress.currentPhase = 'scripts'; $progress.phasesStatus['scripts'] = 'running'; Write-ScanProgress
    Write-PhaseLog 'scripts' 'Scanning script files (.ps1)'
    try {
        $scripts = @(Get-ChildItem -Path $WorkspacePath -Recurse -Include '*.ps1' -File -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = $_.FullName.Substring($WorkspacePath.Length).TrimStart('\/')
                -not ($rel -split '[\\/]' | Where-Object { $ExcludedFolders -contains $_ })
            })
        $varCount = 0; $scriptFuncCount = 0
        foreach ($scr in $scripts) {
            try {
                $scrContent = Get-Content -LiteralPath $scr.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
                $scriptFuncCount += @($scrContent | Select-String '^\s*function\s+' | Measure-Object).Count
                $varCount        += @($scrContent | Select-String '\$[A-Za-z]\w+\s*=' | Measure-Object).Count
            } catch {
                Register-SubFailure -Phase 'scripts' -Target ($scr.FullName.Substring($WorkspacePath.Length).TrimStart('\/')) -ErrorMsg $_.Exception.Message
            }
        }
        Write-PhaseLog 'scripts' "Found $(@($scripts).Count) scripts, $scriptFuncCount functions, ~$varCount var assignments" 'INFO'
        $phaseResults['scripts'] = @{ count = @($scripts).Count; functionCount = $scriptFuncCount; variableCount = $varCount }
        $progress.phasesStatus['scripts'] = 'done'; $progress.completedPhases++
        $checkpoint.phases | Add-Member -MemberType NoteProperty -Name 'scripts' -Value @{ count = @($scripts).Count; functionCount = $scriptFuncCount; completedAt = (Get-Date -Format 'o'); durationMs = [int]((Get-Date) - $phaseStart).TotalMilliseconds; status = 'done' } -Force
    } catch {
        $errMsg = "$_"
        Write-PhaseLog 'scripts' "FAILED: $errMsg" 'ERROR'
        $progress.phasesStatus['scripts'] = 'error'
        $phaseResults['scripts'] = @{ error = $errMsg }
        $null = $bugsToPush.Add((New-ScanPhaseBug -Phase 'scripts' -ErrorMsg $errMsg))
    }
    Write-ScanProgress
}

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 4: Configs
# ══════════════════════════════════════════════════════════════════════════════
if ($RunPhases -contains 'configs') {
    $phaseStart = Get-Date
    $progress.currentPhase = 'configs'; $progress.phasesStatus['configs'] = 'running'; Write-ScanProgress
    Write-PhaseLog 'configs' 'Scanning config files (.json)'
    try {
        $configs = @(Get-ChildItem -Path $WorkspacePath -Recurse -Include '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = $_.FullName.Substring($WorkspacePath.Length).TrimStart('\/')
                -not ($rel -split '[\\/]' | Where-Object { $ExcludedFolders -contains $_ })
            })
        Write-PhaseLog 'configs' "Found $(@($configs).Count) json config files" 'INFO'
        $phaseResults['configs'] = @{ count = @($configs).Count }
        $progress.phasesStatus['configs'] = 'done'; $progress.completedPhases++
        $checkpoint.phases | Add-Member -MemberType NoteProperty -Name 'configs' -Value @{ count = @($configs).Count; completedAt = (Get-Date -Format 'o'); durationMs = [int]((Get-Date) - $phaseStart).TotalMilliseconds; status = 'done' } -Force
    } catch {
        $errMsg = "$_"
        Write-PhaseLog 'configs' "FAILED: $errMsg" 'ERROR'
        $progress.phasesStatus['configs'] = 'error'
        $phaseResults['configs'] = @{ error = $errMsg }
        $null = $bugsToPush.Add((New-ScanPhaseBug -Phase 'configs' -ErrorMsg $errMsg))
    }
    Write-ScanProgress
}

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 5: URLs and IPs
# ══════════════════════════════════════════════════════════════════════════════
if ($RunPhases -contains 'urls_ips') {
    $phaseStart = Get-Date
    $progress.currentPhase = 'urls_ips'; $progress.phasesStatus['urls_ips'] = 'running'; Write-ScanProgress
    Write-PhaseLog 'urls_ips' 'Extracting URLs and IPs from scripts and modules'
    try {
        $urlPattern = 'https?://[^\s''"">\])]+'
        $ipPattern  = '\b(?:\d{1,3}\.){3}\d{1,3}\b'
        $urlFiles   = [System.Collections.ArrayList]@()
        $uniqueUrls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $uniqueIPs  = [System.Collections.Generic.HashSet[string]]::new()
        $scanTargets = @(Get-ChildItem -Path $WorkspacePath -Recurse -Include '*.ps1','*.psm1','*.psd1','*.json','*.xhtml' -File -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = $_.FullName.Substring($WorkspacePath.Length).TrimStart('\/')
                -not ($rel -split '[\\/]' | Where-Object { $ExcludedFolders -contains $_ })
            })
        foreach ($f in $scanTargets) {
            try {
                $txt  = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ([string]::IsNullOrEmpty($txt)) { continue }
                $urls = @([System.Text.RegularExpressions.Regex]::Matches($txt, $urlPattern) | ForEach-Object { $_.Value })
                $ips  = @([System.Text.RegularExpressions.Regex]::Matches($txt, $ipPattern) | ForEach-Object { $_.Value } | Where-Object { $_ -ne '0.0.0.0' -and $_ -ne '255.255.255.255' })
                if (@($urls).Count -gt 0 -or @($ips).Count -gt 0) {
                    $null = $urlFiles.Add([pscustomobject]@{
                        file = $f.FullName.Substring($WorkspacePath.Length).TrimStart('\/')
                        urls = $urls
                        ips  = $ips
                    })
                    foreach ($u in $urls) { $null = $uniqueUrls.Add($u) }
                    foreach ($ip in $ips) { $null = $uniqueIPs.Add($ip) }
                }
            } catch {
                Register-SubFailure -Phase 'urls_ips' -Target ($f.FullName.Substring($WorkspacePath.Length).TrimStart('\/')) -ErrorMsg $_.Exception.Message
            }
        }
        Write-PhaseLog 'urls_ips' "Found $(@($uniqueUrls).Count) unique URLs, $(@($uniqueIPs).Count) unique IPs across $(@($urlFiles).Count) files" 'INFO'
        $phaseResults['urls_ips'] = @{ urlFileCount = @($urlFiles).Count; uniqueUrls = @($uniqueUrls).Count; uniqueIPs = @($uniqueIPs).Count; urlIpByFile = @($urlFiles) }
        $progress.phasesStatus['urls_ips'] = 'done'; $progress.completedPhases++
        $checkpoint.phases | Add-Member -MemberType NoteProperty -Name 'urls_ips' -Value @{ urlFileCount = @($urlFiles).Count; uniqueIPs = @($uniqueIPs).Count; completedAt = (Get-Date -Format 'o'); durationMs = [int]((Get-Date) - $phaseStart).TotalMilliseconds; status = 'done' } -Force
    } catch {
        $errMsg = "$_"
        Write-PhaseLog 'urls_ips' "FAILED: $errMsg" 'ERROR'
        $progress.phasesStatus['urls_ips'] = 'error'
        $phaseResults['urls_ips'] = @{ error = $errMsg }
        $null = $bugsToPush.Add((New-ScanPhaseBug -Phase 'urls_ips' -ErrorMsg $errMsg))
    }
    Write-ScanProgress
}

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 6: DNS Resolution
# ══════════════════════════════════════════════════════════════════════════════
if ($RunPhases -contains 'dns_resolution') {
    $phaseStart = Get-Date
    $progress.currentPhase = 'dns_resolution'; $progress.phasesStatus['dns_resolution'] = 'running'; Write-ScanProgress
    Write-PhaseLog 'dns_resolution' 'Resolving unique hostnames extracted from URLs'
    try {
        $urlsFromPhase5 = if ((Test-MapHasKey -Map $phaseResults -Key 'urls_ips') -and (Test-MapHasKey -Map $phaseResults['urls_ips'] -Key 'urlIpByFile')) {
            @($phaseResults['urls_ips'].urlIpByFile) | ForEach-Object { $_.urls } | Select-Object -Unique
        } else { @() }
        $hosts = @($urlsFromPhase5 | ForEach-Object {
            try { ([System.Uri]$_).Host } catch { '' }
        } | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique)
        $resolved = [System.Collections.ArrayList]@()
        $dnsHitCount = 0
        foreach ($h in $hosts) {
            $ip = $null
            try {
                $dnsTask = [System.Net.Dns]::GetHostAddressesAsync($h)
                if (-not $dnsTask.Wait(3000)) {
                    $ip = 'unresolved'
                    Register-SubFailure -Phase 'dns_resolution' -Target $h -ErrorMsg 'DNS timeout after 3000ms'
                } else {
                    $addrList = @($dnsTask.Result | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
                    if (@($addrList).Count -gt 0) {
                        $ip = $addrList[0].ToString()
                        $dnsHitCount++
                    } else {
                        $ip = 'unresolved'
                    }
                }
            } catch {
                $ip = 'unresolved'
                Register-SubFailure -Phase 'dns_resolution' -Target $h -ErrorMsg $_.Exception.Message
            }
            if ($null -eq $ip) {
                $ip = 'unresolved'
            }
            $null = $resolved.Add([pscustomobject]@{ host = $h; ip = $ip })
        }
        Write-PhaseLog 'dns_resolution' "Resolved $dnsHitCount / $(@($hosts).Count) hosts" 'INFO'
        $phaseResults['dns_resolution'] = @{ hostsChecked = @($hosts).Count; resolved = $dnsHitCount; entries = @($resolved) }
        $progress.phasesStatus['dns_resolution'] = 'done'; $progress.completedPhases++
        $checkpoint.phases | Add-Member -MemberType NoteProperty -Name 'dns_resolution' -Value @{ hostsChecked = @($hosts).Count; resolved = $dnsHitCount; completedAt = (Get-Date -Format 'o'); durationMs = [int]((Get-Date) - $phaseStart).TotalMilliseconds; status = 'done' } -Force
    } catch {
        $errMsg = "$_"
        Write-PhaseLog 'dns_resolution' "FAILED: $errMsg" 'ERROR'
        $progress.phasesStatus['dns_resolution'] = 'error'
        $phaseResults['dns_resolution'] = @{ error = $errMsg }
        $null = $bugsToPush.Add((New-ScanPhaseBug -Phase 'dns_resolution' -ErrorMsg $errMsg))
    }
    Write-ScanProgress
}

# ─── Finalise progress ────────────────────────────────────────────────────────
$progress.finishedAt  = Get-Date -Format 'o'
$progress.currentPhase = $null
$errorCount = @($bugsToPush).Count
$progress.status = if ($errorCount -gt 0) { 'partial' } else { 'done' }
$progress.error  = if ($errorCount -gt 0) { "$errorCount phase(s) failed - see pipeline for BUGS2FIX" } else { $null }
Write-ScanProgress

if (@($subFailures).Count -gt 0) {
    $samples = @($subFailures | Select-Object -First 5 | ForEach-Object { "$($_.phase):$($_.target)" })
    $subMsg = "Subroutine failures detected: $(@($subFailures).Count). Samples: $($samples -join ', ')"
    Write-PhaseLog 'subroutine' $subMsg 'WARN'
    $null = $bugsToPush.Add((New-ScanPhaseBug -Phase 'subroutine' -ErrorMsg $subMsg))
}

# ─── Save checkpoint ─────────────────────────────────────────────────────────
$checkpoint | Add-Member -MemberType NoteProperty -Name 'generated' -Value (Get-Date -Format 'o') -Force
$checkpoint | Add-Member -MemberType NoteProperty -Name 'mode' -Value 'Static' -Force
Save-Checkpoint -Data $checkpoint

# ─── Write full report ────────────────────────────────────────────────────────
$report = [pscustomobject]@{
    schemaVersion  = 'StaticScan/1.0'
    generated      = $progress.finishedAt
    mode           = 'Static'
    workspace      = $WorkspacePath
    durationSec    = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    summary        = $progress
    phases         = $phaseResults
    bugsCreated    = @($bugsToPush).Count
}
try {
    ConvertTo-Json -InputObject $report -Depth 10 |
        Set-Content -LiteralPath $ReportFile -Encoding UTF8
    Write-PhaseLog 'report' "Report saved: $ReportFile" 'INFO'
} catch {
    Write-PhaseLog 'report' "Failed to write report: $_" 'WARN'
}

# ─── Push bugs to pipeline ────────────────────────────────────────────────────
if (@($bugsToPush).Count -gt 0 -and (Test-Path -LiteralPath $PipelinePath)) {
    try {
        $pipeRaw = Get-Content -LiteralPath $PipelinePath -Raw -Encoding UTF8
        $pipe    = $pipeRaw | ConvertFrom-Json
        $existingIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($b in @($pipe.bugs)) {
            if ($null -ne $b -and -not [string]::IsNullOrEmpty($b.id)) { $null = $existingIds.Add($b.id) }
        }
        $newBugs = [System.Collections.ArrayList]@()
        foreach ($b in @($pipe.bugs)) { $null = $newBugs.Add($b) }
        $addedCount = 0
        foreach ($bug in $bugsToPush) {
            if (-not $existingIds.Contains($bug.id)) {
                $null = $newBugs.Add($bug); $addedCount++
            }
        }
        $pipe.bugs = @($newBugs)
        if ($null -ne $pipe.meta) { $pipe.meta.lastModified = Get-Date -Format 'o' }
        ConvertTo-Json -InputObject $pipe -Depth 10 |
            Set-Content -LiteralPath $PipelinePath -Encoding UTF8
        Write-PhaseLog 'pipeline' "Pushed $addedCount BUGS2FIX items to pipeline" 'INFO'
    } catch {
        Write-PhaseLog 'pipeline' "Failed to update pipeline: $_" 'WARN'
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────────
$sw.Stop()
Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════'
Write-Host '  STATIC WORKSPACE SCAN SUMMARY'
Write-Host '═══════════════════════════════════════════════════════════════'
foreach ($ph in $AllPhases) {
    $st = $progress.phasesStatus[$ph]
    $clr = if ($st -eq 'ok') { 'Green' } elseif ($st -eq 'error') { 'Red' } elseif ($st -eq 'skipped') { 'DarkGray' } else { 'Yellow' }
    Write-Host ("  {0,-20} {1}" -f $ph, $st.ToUpper()) -ForegroundColor $clr
}
Write-Host ''
Write-Host "  Elapsed: $([Math]::Round($sw.Elapsed.TotalSeconds,1))s  |  Bugs pushed: $(@($bugsToPush).Count)  |  Report: $(Split-Path $ReportFile -Leaf)"
Write-Host '═══════════════════════════════════════════════════════════════'

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





