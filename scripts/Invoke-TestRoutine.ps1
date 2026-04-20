# VersionTag: 2604.B2.V31.0
# FileRole: Pipeline
#Requires -Version 5.1
<#
.SYNOPSIS
    Executes a Testing Routine Builder JSON template sequentially.

.DESCRIPTION
    Loads a test routine JSON file (schema PsGUI-TestRoutine/1.0) and
    runs each step in order.  Supports 22 condition types:
        FileExists, FolderExists, FolderWritable, ServiceRunning,
        ServiceExists, AppInstalled, AppRunning, AppVersionHigher,
        UserIsAdmin, RemotePathAccessible, DriveMappingExists,
        DNSForward, DNSReverse, TimezoneEquals, LanguageEquals,
        RegionEquals, UserExists, UserIsLocalAdmin, BiosVersionHigher,
        WinRMEnabled, WinRMSecured, WinVersionCurrent

    Results are colour-coded in the console:
        GREEN   = pass / match
        RED     = fail / mismatch
        YELLOW  = error during execution

    Use -Remediate to also run any IF-FAIL remediation commands.

.PARAMETER TemplatePath
    Path to the JSON template file. If omitted, opens a file dialog.

.PARAMETER Remediate
    When set, executes remediation commands on failed steps.

.PARAMETER OutputJson
    When set, writes a results JSON to ~REPORTS/.

.EXAMPLE
    .\scripts\Invoke-TestRoutine.ps1 -TemplatePath config\CONFIG-TEMPLATES\TESTING-TEMPLATES\example-baseline.json

.EXAMPLE
    .\scripts\Invoke-TestRoutine.ps1 -Remediate

.NOTES
    Author  : PwShGUI / FocalPoint-null
    Version : 2604.B2.V31.0
    Created : 2026-03-09
#>

param(
    [string]$TemplatePath,
    [switch]$Remediate,
    [switch]$OutputJson
)

$ErrorActionPreference = 'Continue'
$scriptRoot = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { $PWD.Path }

# ── Load template ─────────────────────────────────────────
if (-not $TemplatePath) {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Title  = 'Select Test Routine Template'
    $dlg.Filter = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
    $dlg.InitialDirectory = Join-Path $scriptRoot 'config\CONFIG-TEMPLATES\TESTING-TEMPLATES'
    if ($dlg.ShowDialog() -ne 'OK') {
        $dlg.Dispose()
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return
    }
    $TemplatePath = $dlg.FileName
    $dlg.Dispose()
}

if (-not (Test-Path $TemplatePath)) {
    Write-Host "Template not found: $TemplatePath" -ForegroundColor Red
    return
}

$template = Get-Content $TemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $template.steps -or $template.steps.Count -eq 0) {
    Write-Host 'Template has no steps.' -ForegroundColor Yellow
    return
}

$routineName = if ($template.meta.name) { $template.meta.name } else { [IO.Path]::GetFileNameWithoutExtension($TemplatePath) }
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Testing Routine: $routineName" -ForegroundColor Cyan
Write-Host "  Steps: $($template.steps.Count)" -ForegroundColor Cyan
Write-Host "  Remediate: $Remediate" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── Result collector ──────────────────────────────────────
$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Result {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Status, [string]$Label, [string]$Type, [string]$Param, [string]$Message, [string]$Remediation)
    $results.Add([pscustomobject]@{
        Status      = $Status
        Label       = $Label
        Type        = $Type
        Param       = $Param
        Message     = $Message
        Remediation = $Remediation
    })
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    $icon  = switch ($Status) { 'PASS' { '[PASS]' } 'FAIL' { '[FAIL]' } default { '[ERR ]' } }
    Write-Host "  $icon $Label" -ForegroundColor $color
    if ($Message) { Write-Host "        $Message" -ForegroundColor DarkGray }
    if ($Remediation) { Write-Host "        REMEDIATION: $Remediation" -ForegroundColor Yellow }
}

# ── Test functions ────────────────────────────────────────
function Test-StepFileExists([string]$p) {
    if (Test-Path -LiteralPath $p -PathType Leaf) { return @{ s='PASS'; m="File exists: $p" } }
    else { return @{ s='FAIL'; m="File not found: $p" } }
}

function Test-StepFolderExists([string]$p) {
    if (Test-Path -LiteralPath $p -PathType Container) { return @{ s='PASS'; m="Folder exists: $p" } }
    else { return @{ s='FAIL'; m="Folder not found: $p" } }
}

function Test-StepFolderWritable([string]$p) {
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { return @{ s='FAIL'; m="Folder does not exist: $p" } }
    $tmp = Join-Path $p ".trb_write_test_$(Get-Random).tmp"
    try { [IO.File]::WriteAllText($tmp, 'test'); Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return @{ s='PASS'; m="Folder is writable: $p" } }
    catch { return @{ s='FAIL'; m="Cannot write to folder: $p" } }
}

function Test-StepServiceRunning([string]$p) {
    $svc = Get-Service -Name $p -ErrorAction SilentlyContinue
    if (-not $svc) { return @{ s='FAIL'; m="Service not found: $p" } }
    if ($svc.Status -eq 'Running') { return @{ s='PASS'; m="Service running: $p" } }
    else { return @{ s='FAIL'; m="Service status: $($svc.Status)" } }
}

function Test-StepServiceExists([string]$p) {
    $svc = Get-Service -Name $p -ErrorAction SilentlyContinue
    if ($svc) { return @{ s='PASS'; m="Service exists: $p (Status: $($svc.Status))" } }
    else { return @{ s='FAIL'; m="Service not found: $p" } }
}

function Test-StepAppInstalled([string]$p) {
    # Check registry uninstall keys
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $found = $false
    foreach ($path in $paths) {
        $apps = Get-ItemProperty $path -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$p*" }
        if ($apps) { $found = $true; break }
    }
    if ($found) { return @{ s='PASS'; m="Application found: $p" } }
    else { return @{ s='FAIL'; m="Application not found in registry: $p" } }
}

function Test-StepAppRunning([string]$p) {
    $proc = Get-Process -Name $p -ErrorAction SilentlyContinue
    if ($proc) { return @{ s='PASS'; m="Process running: $p (PID: $($proc[0].Id))" } }  # SIN-EXEMPT: P027 - array guarded by if(.Count -gt 0) / if($proc) on prior line
    else { return @{ s='FAIL'; m="Process not running: $p" } }
}

function Test-StepAppVersionHigher([string]$p) {
    $parts = $p -split '\|', 2
    if ($parts.Count -lt 2) { return @{ s='ERROR'; m="Format: AppName|MinVersion" } }
    $appName = $parts[0].Trim()
    $minVer  = $parts[1].Trim()
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($path in $paths) {
        $app = Get-ItemProperty $path -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -like "*$appName*" -and $_.DisplayVersion }
        if ($app) {
            try {
                $cur = [version]($app[0].DisplayVersion -replace '[^0-9.]', '')
                $min = [version]$minVer
                if ($cur -ge $min) { return @{ s='PASS'; m="$appName v$($app[0].DisplayVersion) >= $minVer" } }
                else { return @{ s='FAIL'; m="$appName v$($app[0].DisplayVersion) < $minVer" } }  # SIN-EXEMPT: P027 - array guarded by if(.Count -gt 0) / if($proc) on prior line
            } catch { return @{ s='ERROR'; m="Version parse error: $($_.Exception.Message)" } }
        }
    }
    return @{ s='FAIL'; m="Application not found: $appName" }
}

function Test-StepUserIsAdmin([string]$p) {
    $identity = if ($p) {
        try { [Security.Principal.WindowsIdentity]::new($p) } catch { $null }
    } else { [Security.Principal.WindowsIdentity]::GetCurrent() }
    if (-not $identity) { return @{ s='ERROR'; m="Cannot resolve identity: $p" } }
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return @{ s='PASS'; m="User is admin: $($identity.Name)" }
    } else { return @{ s='FAIL'; m="User is NOT admin: $($identity.Name)" } }
}

function Test-StepRemotePathAccessible([string]$p) {
    if (Test-Path -LiteralPath $p) { return @{ s='PASS'; m="UNC path accessible: $p" } }
    else { return @{ s='FAIL'; m="UNC path not accessible: $p" } }
}

function Test-StepDriveMappingExists([string]$p) {
    $letter = ($p -replace '[:\\]', '').ToUpper()
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $letter }
    if ($drives) { return @{ s='PASS'; m="Drive $letter`: mapped to $($drives.Root)" } }
    else { return @{ s='FAIL'; m="Drive $letter`: not mapped" } }
}

function Test-StepDNSForward([string]$p) {
    try {
        $r = Resolve-DnsName -Name $p -ErrorAction Stop
        $ips = ($r | Where-Object { $_.QueryType -eq 'A' -or $_.QueryType -eq 'AAAA' }).IPAddress -join ', '
        return @{ s='PASS'; m="$p resolves to: $ips" }
    } catch { return @{ s='FAIL'; m="DNS forward failed for $p`: $($_.Exception.Message)" } }
}

function Test-StepDNSReverse([string]$p) {
    try {
        $r = Resolve-DnsName -Name $p -Type PTR -ErrorAction Stop
        $names = ($r.NameHost) -join ', '
        return @{ s='PASS'; m="$p resolves to: $names" }
    } catch { return @{ s='FAIL'; m="DNS reverse failed for $p`: $($_.Exception.Message)" } }
}

function Test-StepTimezoneEquals([string]$p) {
    $tz = [TimeZoneInfo]::Local
    $offset = $tz.BaseUtcOffset.TotalHours
    $expected = [double]$p
    if ($offset -eq $expected) { return @{ s='PASS'; m="Timezone offset +$offset matches +$expected ($($tz.Id))" } }
    else { return @{ s='FAIL'; m="Timezone offset +$offset, expected +$expected ($($tz.Id))" } }
}

function Test-StepLanguageEquals([string]$p) {
    $lang = (Get-Culture).Name
    if ($lang -eq $p) { return @{ s='PASS'; m="Language is $lang" } }
    else { return @{ s='FAIL'; m="Language is $lang, expected $p" } }
}

function Test-StepRegionEquals([string]$p) {
    $region = (Get-Culture).DisplayName
    $geoName = try { [System.Globalization.RegionInfo]::CurrentRegion.EnglishName } catch { '' }
    if ($geoName -like "*$p*" -or $region -like "*$p*") {
        return @{ s='PASS'; m="Region matches: $geoName" }
    } else { return @{ s='FAIL'; m="Region is '$geoName', expected '$p'" } }
}

function Test-StepUserExists([string]$p) {
    try {
        $user = Get-LocalUser -Name $p -ErrorAction Stop
        return @{ s='PASS'; m="User exists: $($user.Name) (Enabled: $($user.Enabled))" }
    } catch { return @{ s='FAIL'; m="User not found: $p" } }
}

function Test-StepUserIsLocalAdmin([string]$p) {
    try {
        $members = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop
        $match = $members | Where-Object { $_.Name -like "*$p*" }
        if ($match) { return @{ s='PASS'; m="$p is a local admin" } }
        else { return @{ s='FAIL'; m="$p is NOT in local Administrators group" } }
    } catch { return @{ s='ERROR'; m="Cannot query Administrators group: $($_.Exception.Message)" } }
}

function Test-StepBiosVersionHigher([string]$p) {
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $current = $bios.SMBIOSBIOSVersion
        if ([string]::Compare($current, $p, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return @{ s='PASS'; m="BIOS $current >= $p" }
        } else { return @{ s='FAIL'; m="BIOS $current < $p" } }
    } catch { return @{ s='ERROR'; m="Cannot query BIOS: $($_.Exception.Message)" } }
}

function Test-StepWinRMEnabled([string]$p) {
    try {
        $svc = Get-Service -Name WinRM -ErrorAction Stop
        if ($svc.Status -eq 'Running') { return @{ s='PASS'; m="WinRM service is running" } }
        else { return @{ s='FAIL'; m="WinRM service status: $($svc.Status)" } }
    } catch { return @{ s='FAIL'; m="WinRM service not found" } }
}

function Test-StepWinRMSecured([string]$p) {
    try {
        $listeners = Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop
        $https = $listeners | Where-Object { $_.Keys -contains 'Transport=HTTPS' }
        if ($https) { return @{ s='PASS'; m="WinRM HTTPS listener found" } }
        else { return @{ s='FAIL'; m="No WinRM HTTPS listener configured" } }
    } catch { return @{ s='ERROR'; m="Cannot query WinRM listeners: $($_.Exception.Message)" } }
}

function Test-StepWinVersionCurrent([string]$p) {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $build = [int]$os.BuildNumber
        # Approximate: check if within 2 major builds of latest known public channel
        # As of March 2026, Windows 11 24H2 = 26100, Windows 11 23H2 = 22631
        $latestKnown = 26100
        $diff = $latestKnown - $build
        if ($diff -le 2000) { return @{ s='PASS'; m="Build $build is within range of latest ($latestKnown)" } }
        else { return @{ s='FAIL'; m="Build $build is $diff behind latest ($latestKnown)" } }
    } catch { return @{ s='ERROR'; m="Cannot query OS version: $($_.Exception.Message)" } }
}

# ── Dispatch ──────────────────────────────────────────────
$dispatchTable = @{
    'FileExists'           = { param($p) Test-StepFileExists $p }
    'FolderExists'         = { param($p) Test-StepFolderExists $p }
    'FolderWritable'       = { param($p) Test-StepFolderWritable $p }
    'ServiceRunning'       = { param($p) Test-StepServiceRunning $p }
    'ServiceExists'        = { param($p) Test-StepServiceExists $p }
    'AppInstalled'         = { param($p) Test-StepAppInstalled $p }
    'AppRunning'           = { param($p) Test-StepAppRunning $p }
    'AppVersionHigher'     = { param($p) Test-StepAppVersionHigher $p }
    'UserIsAdmin'          = { param($p) Test-StepUserIsAdmin $p }
    'RemotePathAccessible' = { param($p) Test-StepRemotePathAccessible $p }
    'DriveMappingExists'   = { param($p) Test-StepDriveMappingExists $p }
    'DNSForward'           = { param($p) Test-StepDNSForward $p }
    'DNSReverse'           = { param($p) Test-StepDNSReverse $p }
    'TimezoneEquals'       = { param($p) Test-StepTimezoneEquals $p }
    'LanguageEquals'       = { param($p) Test-StepLanguageEquals $p }
    'RegionEquals'         = { param($p) Test-StepRegionEquals $p }
    'UserExists'           = { param($p) Test-StepUserExists $p }
    'UserIsLocalAdmin'     = { param($p) Test-StepUserIsLocalAdmin $p }
    'BiosVersionHigher'    = { param($p) Test-StepBiosVersionHigher $p }
    'WinRMEnabled'         = { param($p) Test-StepWinRMEnabled $p }
    'WinRMSecured'         = { param($p) Test-StepWinRMSecured $p }
    'WinVersionCurrent'    = { param($p) Test-StepWinVersionCurrent $p }
}

# ── Execute steps sequentially ────────────────────────────
$stepNum = 0
foreach ($step in $template.steps) {
    $stepNum++
    Write-Host "`n[$stepNum/$($template.steps.Count)] $($step.label)" -ForegroundColor White

    $handler = $dispatchTable[$step.type]
    if (-not $handler) {
        Add-Result -Status 'ERROR' -Label $step.label -Type $step.type -Param $step.param `
                   -Message "Unknown test type: $($step.type)" -Remediation ''
        continue
    }

    try {
        $r = & $handler $step.param
        $status = $r.s
        $msg    = $r.m
    } catch {
        $status = 'ERROR'
        $msg    = "Exception: $($_.Exception.Message)"
    }

    $remResult = ''
    if ($status -eq 'FAIL' -and $Remediate -and $step.remediation) {
        Write-Host "        Running remediation: $($step.remediation)" -ForegroundColor Yellow
        try {
            & ([scriptblock]::Create($step.remediation))
            $remResult = "Remediation executed: $($step.remediation)"
        } catch {
            $remResult = "Remediation failed: $($_.Exception.Message)"
        }
    }

    Add-Result -Status $status -Label $step.label -Type $step.type -Param $step.param `
               -Message $msg -Remediation $remResult
}

# ── Summary ───────────────────────────────────────────────
$pass  = ($results | Where-Object Status -eq 'PASS').Count
$fail  = ($results | Where-Object Status -eq 'FAIL').Count
$error2 = ($results | Where-Object Status -eq 'ERROR').Count

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $pass PASS  |  $fail FAIL  |  $error2 ERROR" -ForegroundColor Cyan
Write-Host "  Pass Rate: $(if($results.Count -gt 0){ [math]::Round(($pass / $results.Count)*100) }else{ 0 })%" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── Optional JSON output ──────────────────────────────────
if ($OutputJson) {
    $outDir  = Join-Path $scriptRoot '~REPORTS'
    if (-not (Test-Path $outDir)) { New-Item $outDir -ItemType Directory -Force | Out-Null }
    $outFile = Join-Path $outDir "test-routine-results_$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $output  = @{
        routine    = $routineName
        template   = $TemplatePath
        executed   = (Get-Date).ToString('o')
        remediate  = [bool]$Remediate
        summary    = @{ pass=$pass; fail=$fail; error=$error2; total=$results.Count }
        results    = $results | ForEach-Object {
            @{ Status=$_.Status; Label=$_.Label; Type=$_.Type; Param=$_.Param; Message=$_.Message; Remediation=$_.Remediation }
        }
    }
    $output | ConvertTo-Json -Depth 4 | Set-Content $outFile -Encoding UTF8
    Write-Host "Results saved: $outFile" -ForegroundColor Green
}

return $results


