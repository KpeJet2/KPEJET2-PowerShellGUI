# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS
    Chaos testing conditions for PwShGUI smoke test resilience validation.
.DESCRIPTION
    Introduces controlled faults into a COPY of the workspace to test resilience.
    Original workspace is NEVER modified -- all mutations in staging directory.
.PARAMETER WorkspacePath
    Root of the PwShGUI workspace.
.PARAMETER StagingPath
    Temporary staging directory for the mutated copy.
.PARAMETER Conditions
    Condition codes to apply (C01-C12). Default: all.
.PARAMETER RunSmokeTest
    Run smoke test against the staged copy after applying chaos.
.PARAMETER KeepStaging
    Keep staging directory after completion.
.PARAMETER HeadlessOnly
    Pass -HeadlessOnly to the smoke test.
#>
param(
    [string]$WorkspacePath,
    [string]$StagingPath,
    [string[]]$Conditions,
    [switch]$RunSmokeTest,
    [switch]$KeepStaging,
    [switch]$HeadlessOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $WorkspacePath) {
    $WorkspacePath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
if (-not $StagingPath) {
    $StagingPath = Join-Path $env:TEMP 'PwShGUI-Chaos'
}

$allConditions = @('C01','C02','C03','C04','C05','C06','C07','C08','C09','C10','C11','C12')
if (-not $Conditions -or $Conditions.Count -eq 0) { $Conditions = $allConditions }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$chaosLog  = @()

function Write-Chaos {
    param([string]$Code, [string]$Status, [string]$Detail)
    $entry = [PSCustomObject]@{ Time = (Get-Date -Format 'HH:mm:ss'); Code = $Code; Status = $Status; Detail = $Detail }
    $script:chaosLog += $entry
    $color = switch ($Status) { 'APPLY' { 'Yellow' } 'OK' { 'Green' } 'SKIP' { 'DarkGray' } 'ERROR' { 'Red' } default { 'White' } }
    Write-Host "  [$Status] $Code  $Detail" -ForegroundColor $color
}

# -- Stage workspace copy
Write-Host "`n$("=" * 68)" -ForegroundColor Magenta
Write-Host "  CHAOS TEST CONDITIONS  --  $env:COMPUTERNAME" -ForegroundColor Yellow
Write-Host "$("=" * 68)`n" -ForegroundColor Magenta

Write-Host "[Stage] Creating workspace copy..." -ForegroundColor Cyan
if (Test-Path $StagingPath) { Remove-Item $StagingPath -Recurse -Force -EA SilentlyContinue }
$excludeDirs = @('.history','temp','__pycache__','node_modules','.git','~DOWNLOADS')
$sourceItems = Get-ChildItem $WorkspacePath -Force | Where-Object { $_.Name -notin $excludeDirs }
New-Item -ItemType Directory -Path $StagingPath -Force | Out-Null
foreach ($item in $sourceItems) {
    if ($item.PSIsContainer) { Copy-Item $item.FullName (Join-Path $StagingPath $item.Name) -Recurse -Force -EA SilentlyContinue }
    else { Copy-Item $item.FullName (Join-Path $StagingPath $item.Name) -Force -EA SilentlyContinue }
}
Write-Host "[Stage] Staged to: $StagingPath`n" -ForegroundColor Green

$lockedStreams = @()

# C01: Missing Config
if ('C01' -in $Conditions) {
    $t = Join-Path $StagingPath 'config\system-variables.xml'
    if (Test-Path $t) { Remove-Item $t -Force; Write-Chaos 'C01' 'APPLY' 'Deleted system-variables.xml' }
    else { Write-Chaos 'C01' 'SKIP' 'system-variables.xml not found' }
} else { Write-Chaos 'C01' 'SKIP' 'Not selected' }

# C02: Corrupt Config XML
if ('C02' -in $Conditions) {
    $t = Join-Path $StagingPath 'config\system-variables.xml'
    if (Test-Path $t) {
        $xml = Get-Content $t -Raw
        $corrupted = $xml.Insert([math]::Min(50, $xml.Length), '<<<CHAOS_CORRUPT>>>')
        Set-Content $t -Value $corrupted -Encoding UTF8
        Write-Chaos 'C02' 'APPLY' 'Injected malformed XML'
    } elseif ('C01' -in $Conditions) {
        Set-Content $t -Value '<?xml version="1.0"?><root><<<BROKEN' -Encoding UTF8
        Write-Chaos 'C02' 'APPLY' 'Created malformed system-variables.xml'
    } else { Write-Chaos 'C02' 'SKIP' 'Not found' }
} else { Write-Chaos 'C02' 'SKIP' 'Not selected' }

# C03: Missing Module
if ('C03' -in $Conditions) {
    $t = Join-Path $StagingPath 'modules\PwShGUI-Theme.psm1'
    if (Test-Path $t) { Remove-Item $t -Force; Write-Chaos 'C03' 'APPLY' 'Deleted PwShGUI-Theme.psm1' }
    else { Write-Chaos 'C03' 'SKIP' 'Not found' }
} else { Write-Chaos 'C03' 'SKIP' 'Not selected' }

# C04: Empty Module
if ('C04' -in $Conditions) {
    $t = Join-Path $StagingPath 'modules\CronAiAthon-EventLog.psm1'
    if (Test-Path $t) { Set-Content $t -Value '' -Encoding UTF8; Write-Chaos 'C04' 'APPLY' 'Truncated CronAiAthon-EventLog.psm1' }
    else { Write-Chaos 'C04' 'SKIP' 'Not found' }
} else { Write-Chaos 'C04' 'SKIP' 'Not selected' }

# C05: Corrupt JSON
if ('C05' -in $Conditions) {
    $t = Join-Path $StagingPath 'config\cron-aiathon-pipeline.json'
    if (Test-Path $t) { Set-Content $t -Value '{ "meta": { CHAOS_BROKEN' -Encoding UTF8; Write-Chaos 'C05' 'APPLY' 'Corrupted pipeline JSON' }
    else { Write-Chaos 'C05' 'SKIP' 'Not found' }
} else { Write-Chaos 'C05' 'SKIP' 'Not selected' }

# C06: Missing Logs Dir
if ('C06' -in $Conditions) {
    $t = Join-Path $StagingPath 'logs'
    if (Test-Path $t) { Remove-Item $t -Recurse -Force; Write-Chaos 'C06' 'APPLY' 'Deleted logs directory' }
    else { Write-Chaos 'C06' 'SKIP' 'Not found' }
} else { Write-Chaos 'C06' 'SKIP' 'Not selected' }

# C07: Read-Only Config
if ('C07' -in $Conditions) {
    $configs = Get-ChildItem (Join-Path $StagingPath 'config') -File -EA SilentlyContinue
    $count = 0
    foreach ($c in $configs) { Set-ItemProperty $c.FullName -Name IsReadOnly -Value $true; $count++ }
    if ($count -gt 0) { Write-Chaos 'C07' 'APPLY' "Set $count config files to read-only" }
    else { Write-Chaos 'C07' 'SKIP' 'No config files' }
} else { Write-Chaos 'C07' 'SKIP' 'Not selected' }

# C08: Giant Log File (50MB)
if ('C08' -in $Conditions) {
    $logsDir = Join-Path $StagingPath 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
    $t = Join-Path $logsDir 'CHAOS-giant-log.log'
    $chunk = 'X' * 1024 + "`n"
    $sb2 = [System.Text.StringBuilder]::new($chunk.Length * 1024)
    for ($i = 0; $i -lt 1024; $i++) { $sb2.Append($chunk) | Out-Null }
    $oneMB = $sb2.ToString()
    $stream = [System.IO.StreamWriter]::new($t, $false, [System.Text.Encoding]::UTF8)
    for ($i = 0; $i -lt 50; $i++) { $stream.Write($oneMB) }
    $stream.Close()
    $sizeMB = [math]::Round((Get-Item $t).Length / 1MB, 1)
    Write-Chaos 'C08' 'APPLY' "Created ${sizeMB}MB dummy log file"
} else { Write-Chaos 'C08' 'SKIP' 'Not selected' }

# C09: Missing Script
if ('C09' -in $Conditions) {
    $t = Join-Path $StagingPath 'scripts\Invoke-OrphanAudit.ps1'
    if (Test-Path $t) { Remove-Item $t -Force; Write-Chaos 'C09' 'APPLY' 'Deleted Invoke-OrphanAudit.ps1' }
    else { Write-Chaos 'C09' 'SKIP' 'Not found' }
} else { Write-Chaos 'C09' 'SKIP' 'Not selected' }

# C10: Duplicate Module Load
if ('C10' -in $Conditions) {
    $src = Join-Path $StagingPath 'modules\PwShGUICore.psm1'
    $dst = Join-Path $StagingPath 'modules\PwShGUICore-Duplicate.psm1'
    if (Test-Path $src) { Copy-Item $src $dst -Force; Write-Chaos 'C10' 'APPLY' 'Created PwShGUICore-Duplicate.psm1' }
    else { Write-Chaos 'C10' 'SKIP' 'PwShGUICore.psm1 not found' }
} else { Write-Chaos 'C10' 'SKIP' 'Not selected' }

# C11: Env Variable Perturbation
if ('C11' -in $Conditions) {
    $envScript = Join-Path $StagingPath 'config\chaos-env.ps1'
    $envContent = "# Chaos C11: Env perturbation`n" + '$env:PWSHGUI_CHAOS_MODE = "true"' + "`n" + '$env:PWSHGUI_ORIGINAL_COMPUTERNAME = $env:COMPUTERNAME'
    Set-Content $envScript -Value $envContent -Encoding UTF8
    Write-Chaos 'C11' 'APPLY' 'Created chaos-env.ps1 with env perturbation'
} else { Write-Chaos 'C11' 'SKIP' 'Not selected' }

# C12: Locked File
if ('C12' -in $Conditions) {
    $t = Join-Path $StagingPath 'config\links.json'
    if (Test-Path $t) {
        try {
            $fs = [System.IO.File]::Open($t, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $lockedStreams += $fs
            Write-Chaos 'C12' 'APPLY' 'Locked links.json with exclusive handle'
        } catch { Write-Chaos 'C12' 'ERROR' "Failed to lock: $_" }
    } else { Write-Chaos 'C12' 'SKIP' 'links.json not found' }
} else { Write-Chaos 'C12' 'SKIP' 'Not selected' }

# -- Summary
$applied = @($chaosLog | Where-Object { $_.Status -eq 'APPLY' }).Count
$skipped = @($chaosLog | Where-Object { $_.Status -eq 'SKIP' }).Count
$errors  = @($chaosLog | Where-Object { $_.Status -eq 'ERROR' }).Count

Write-Host "`n$("=" * 68)" -ForegroundColor Magenta
Write-Host "  Chaos Conditions:  APPLIED=$applied  SKIPPED=$skipped  ERRORS=$errors" -ForegroundColor Yellow
Write-Host "$("=" * 68)" -ForegroundColor Magenta

# -- Run smoke test
$smokeExitCode = 0
if ($RunSmokeTest) {
    Write-Host "`n[Chaos] Running smoke test against staged workspace..." -ForegroundColor Cyan
    $smokeScript = Join-Path $StagingPath 'tests\Invoke-GUISmokeTest.ps1'
    if (Test-Path $smokeScript) {
        $smokeArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$smokeScript`"")
        if ($HeadlessOnly) { $smokeArgs += '-HeadlessOnly' }
        $shell = if (Get-Command pwsh.exe -EA SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        $proc = Start-Process $shell -ArgumentList ($smokeArgs -join ' ') -Wait -PassThru -NoNewWindow
        $smokeExitCode = $proc.ExitCode
        if ($smokeExitCode -eq 0) { Write-Host "`n[Chaos] Smoke test PASSED under chaos!" -ForegroundColor Green }
        else { Write-Host "`n[Chaos] Smoke test FAILED (exit $smokeExitCode) -- expected under chaos!" -ForegroundColor Yellow }
    } else { Write-Host "[Chaos] Smoke test script not found in staging!" -ForegroundColor Red }
}

# -- Write chaos report
$reportDir = Join-Path $WorkspacePath 'logs'
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$reportPath = Join-Path $reportDir "$env:COMPUTERNAME-$timestamp-ChaosTest.log"
$reportLines = @(
    "PwShGUI Chaos Test Report -- $env:COMPUTERNAME -- $timestamp"
    "=" * 68
    "Staging Path: $StagingPath"
    "Conditions Applied: $applied / $($Conditions.Count)"
    "Smoke Test Exit: $smokeExitCode"
    "=" * 68
    ""
)
foreach ($entry in $chaosLog) { $reportLines += "[$($entry.Status)] $($entry.Code)  $($entry.Detail)" }
$reportLines | Out-File $reportPath -Encoding UTF8
Write-Host "`nChaos report: $reportPath" -ForegroundColor Green

# -- Cleanup
foreach ($fs in $lockedStreams) { try { $fs.Close(); $fs.Dispose() } catch { <# Intentional: best-effort stream cleanup #> } }
if (-not $KeepStaging) {
    Write-Host "[Cleanup] Removing staging directory..." -ForegroundColor DarkGray
    Get-ChildItem $StagingPath -Recurse -File -EA SilentlyContinue | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item $StagingPath -Recurse -Force -EA SilentlyContinue
    Write-Host "[Cleanup] Done.`n" -ForegroundColor DarkGray
} else { Write-Host "[Cleanup] Staging kept at: $StagingPath`n" -ForegroundColor DarkYellow }

[PSCustomObject]@{
    Timestamp      = $timestamp
    ConditionsUsed = $Conditions
    Applied        = $applied
    Skipped        = $skipped
    Errors         = $errors
    SmokeExitCode  = $smokeExitCode
    ReportPath     = $reportPath
    StagingPath    = if ($KeepStaging) { $StagingPath } else { '(removed)' }
}

