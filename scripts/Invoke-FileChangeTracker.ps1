#Requires -Version 5.1
# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS
# --- Structured lifecycle logging ---
if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
    Write-AppLog -Message "Started: $($MyInvocation.MyCommand.Name)" -Level 'Info'
}
    Cryptographic file change tracking ledger with HMAC-SHA256 signatures.
.DESCRIPTION
    Tracks file renames/moves with:
      - SHA256 hashes before and after
      - Epoch timestamp and ISO-8601 datetime
      - File sizes before/after
      - HMAC-SHA256 signature (key=workspace-local, salt=agent name)
      - Append-only JSON ledger in logs/file-change-ledger.json

    Functions:
      -NewRecord   Record a file rename (old path -> new path)
      -Verify      Verify all ledger records' HMAC signatures
      -Show        Display ledger entries with verification status
      -Test        Round-trip test: create temp file, rename, verify
      -Cascade     After rename, update references across workspace files
.NOTES
    Author   : The Establishment
    Version  : 2604.B2.V31.0
    Created  : 26th March 2026
    Config   : config\file-change-key.bin
.LINK
    ~README.md/REFERENCE-CONSISTENCY-STANDARD.md
#>
param(
    [switch]$NewRecord,
    [switch]$Verify,
    [switch]$Show,
    [switch]$Test,
    [switch]$Cascade,
    [string]$OldPath,
    [string]$NewPath,
    [string]$Agent = 'user',
    [string]$Reason = ''
)

$ErrorActionPreference = 'Stop'
$scriptRoot   = $PSScriptRoot
$projectRoot  = Split-Path $scriptRoot -Parent
$configDir    = Join-Path $projectRoot 'config'
$logsDir      = Join-Path $projectRoot 'logs'
$keyPath      = Join-Path $configDir 'file-change-key.bin'
$ledgerPath   = Join-Path $logsDir 'file-change-ledger.json'

# ---------------------------------------------------------------------------
# Key management
# ---------------------------------------------------------------------------
function Initialize-ChangeKey {
    if (Test-Path $keyPath) { return }
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $key = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($key)
    $rng.Dispose()
    [System.IO.File]::WriteAllBytes($keyPath, $key)
    # Restrict ACL to current user only
    $acl = Get-Acl $keyPath
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'FullControl', 'Allow'
    )
    $acl.AddAccessRule($rule)
    Set-Acl -Path $keyPath -AclObject $acl
    Write-Host "[ChangeTracker] Key generated: $keyPath" -ForegroundColor Green
}

function Get-ChangeKey {
    Initialize-ChangeKey
    return [System.IO.File]::ReadAllBytes($keyPath)
}

# ---------------------------------------------------------------------------
# Hashing
# ---------------------------------------------------------------------------
function Get-FileSHA256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 'sha256:MISSING' }
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $hash = $hasher.ComputeHash($stream)
        return 'sha256:' + [BitConverter]::ToString($hash).Replace('-','').ToLower()
    } finally {
        $stream.Dispose()
        $hasher.Dispose()
    }
}

function Get-FileChangeHMAC {
    param(
        [string]$HashBefore,
        [string]$HashAfter,
        [long]$Epoch,
        [string]$AgentName
    )
    $key = Get-ChangeKey
    $message = "$HashBefore|$HashAfter|$Epoch|$AgentName"
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $key
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    $sig = $hmac.ComputeHash($bytes)
    $hmac.Dispose()
    return 'hmac-sha256:' + [BitConverter]::ToString($sig).Replace('-','').ToLower()
}

# ---------------------------------------------------------------------------
# Ledger I/O
# ---------------------------------------------------------------------------
function Get-Ledger {
    if (-not (Test-Path $ledgerPath)) {
        return @{ ledger = @() }
    }
    $raw = Get-Content $ledgerPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{ ledger = @() } }
    return $raw | ConvertFrom-Json
}

function Save-Ledger {
    param($LedgerObj)
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
    $LedgerObj | ConvertTo-Json -Depth 10 | Set-Content $ledgerPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Record creation
# ---------------------------------------------------------------------------
function New-FileChangeRecord {
    param(
        [Parameter(Mandatory)]
        [string]$OldFilePath,
        [Parameter(Mandatory)]
        [string]$NewFilePath,
        [string]$AgentName = 'user',
        [string]$ChangeReason = ''
    )
    $absOld = if ([System.IO.Path]::IsPathRooted($OldFilePath)) { $OldFilePath } else { Join-Path $projectRoot $OldFilePath }
    $absNew = if ([System.IO.Path]::IsPathRooted($NewFilePath)) { $NewFilePath } else { Join-Path $projectRoot $NewFilePath }

    $hashBefore = Get-FileSHA256 -Path $absOld
    $sizeBefore = if (Test-Path $absOld) { (Get-Item $absOld).Length } else { 0 }
    $hashAfter  = Get-FileSHA256 -Path $absNew
    $sizeAfter  = if (Test-Path $absNew) { (Get-Item $absNew).Length } else { 0 }

    $now   = [DateTimeOffset]::UtcNow
    $epoch = $now.ToUnixTimeSeconds()
    $iso   = $now.ToString('o')

    $relOld = $OldFilePath -replace [regex]::Escape($projectRoot), '' -replace '^[\\/]', ''
    $relNew = $NewFilePath -replace [regex]::Escape($projectRoot), '' -replace '^[\\/]', ''

    $sig = Get-FileChangeHMAC -HashBefore $hashBefore -HashAfter $hashAfter -Epoch $epoch -AgentName $AgentName

    $record = [ordered]@{
        id            = [guid]::NewGuid().ToString()
        timestamp     = $iso
        epoch         = $epoch
        agent         = $AgentName
        oldPath       = $relOld
        newPath       = $relNew
        sizeBefore    = $sizeBefore
        sizeAfter     = $sizeAfter
        hashBefore    = $hashBefore
        hashAfter     = $hashAfter
        hmacSignature = $sig
        reason        = $ChangeReason
    }

    $ledger = Get-Ledger
    $entries = @($ledger.ledger) + @($record)
    $ledger = @{ ledger = $entries }
    Save-Ledger $ledger
    Write-Host "[ChangeTracker] Record added: $relOld -> $relNew" -ForegroundColor Cyan
    return $record
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
function Test-ChangeRecord {
    param($Record)
    $expected = Get-FileChangeHMAC `
        -HashBefore $Record.hashBefore `
        -HashAfter  $Record.hashAfter `
        -Epoch      $Record.epoch `
        -AgentName  $Record.agent
    return ($expected -eq $Record.hmacSignature)
}

function Invoke-LedgerVerify {
    $ledger = Get-Ledger
    if ($ledger.ledger.Count -eq 0) {
        Write-Host "[ChangeTracker] Ledger is empty." -ForegroundColor Yellow
        return
    }
    $pass = 0; $fail = 0
    foreach ($rec in $ledger.ledger) {
        $ok = Test-ChangeRecord $rec
        $status = if ($ok) { 'PASS' } else { 'FAIL' }
        $color  = if ($ok) { 'Green' } else { 'Red' }
        Write-Host ("[{0}] {1} -> {2}  ({3})" -f $status, $rec.oldPath, $rec.newPath, $rec.timestamp) -ForegroundColor $color
        if ($ok) { $pass++ } else { $fail++ }
    }
    Write-Host "`n[ChangeTracker] Verified: $pass PASS, $fail FAIL out of $($ledger.ledger.Count) records." -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------
function Show-ChangeLedger {
    $ledger = Get-Ledger
    if ($ledger.ledger.Count -eq 0) {
        Write-Host "[ChangeTracker] Ledger is empty." -ForegroundColor Yellow
        return
    }
    Write-Host "`n=== File Change Ledger ===" -ForegroundColor Cyan
    Write-Host ("Records: {0}" -f $ledger.ledger.Count)
    Write-Host ""
    foreach ($rec in $ledger.ledger) {
        $ok = Test-ChangeRecord $rec
        $badge = if ($ok) { '[VALID]' } else { '[TAMPERED]' }
        $color = if ($ok) { 'Green' } else { 'Red' }
        Write-Host ("  {0} {1}" -f $badge, $rec.timestamp) -ForegroundColor $color
        Write-Host ("    Old: {0}  ({1} bytes)" -f $rec.oldPath, $rec.sizeBefore)
        Write-Host ("    New: {0}  ({1} bytes)" -f $rec.newPath, $rec.sizeAfter)
        Write-Host ("    Agent: {0}  Reason: {1}" -f $rec.agent, $rec.reason)
        Write-Host ""
    }
}

# ---------------------------------------------------------------------------
# Cascade: update workspace references after rename
# ---------------------------------------------------------------------------
function Update-WorkspaceReferences {
    param(
        [Parameter(Mandatory)][string]$OldName,
        [Parameter(Mandatory)][string]$NewName
    )
    $extensions = @('*.md','*.ps1','*.psm1','*.json','*.xml','*.xhtml','*.html')
    $excludeDirs = @('.history','node_modules','__pycache__','temp','.git')
    $touched = @()

    foreach ($ext in $extensions) {
        $files = Get-ChildItem -Path $projectRoot -Filter $ext -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $skip = $false
                foreach ($ex in $excludeDirs) {
                    if ($_.FullName -like "*\$ex\*") { $skip = $true; break }
                }
                -not $skip
            }
        foreach ($f in $files) {
            $content = Get-Content $f.FullName -Raw -Encoding UTF8
            if ($content -match [regex]::Escape($OldName)) {
                $updated = $content -replace [regex]::Escape($OldName), $NewName
                Set-Content -Path $f.FullName -Value $updated -Encoding UTF8 -NoNewline
                $touched += $f.FullName -replace [regex]::Escape($projectRoot), '' -replace '^[\\/]', ''
            }
        }
    }

    if ($touched.Count -gt 0) {
        Write-Host "[ChangeTracker] Updated references in $($touched.Count) files:" -ForegroundColor Cyan
        $touched | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "[ChangeTracker] No references found for '$OldName'." -ForegroundColor Yellow
    }
    return $touched
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
function Invoke-RoundTripTest {
    Write-Host "`n=== Change Tracker Round-Trip Test ===" -ForegroundColor Cyan
    $tempDir = Join-Path $projectRoot 'temp'
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
    $testOld = Join-Path $tempDir 'change-tracker-test-old.txt'
    $testNew = Join-Path $tempDir 'change-tracker-test-new.txt'
    'Test content for HMAC round-trip' | Set-Content $testOld -Encoding UTF8
    $rec = New-FileChangeRecord -OldFilePath $testOld -NewFilePath $testOld -AgentName 'self-test' -ChangeReason 'Round-trip test'
    $valid = Test-ChangeRecord $rec
    # Remove temp file and test record from ledger
    Remove-Item $testOld -Force -ErrorAction SilentlyContinue
    Remove-Item $testNew -Force -ErrorAction SilentlyContinue
    $ledger = Get-Ledger
    $ledger.ledger = @($ledger.ledger | Where-Object { $_.id -ne $rec.id })
    Save-Ledger $ledger
    if ($valid) {
        Write-Host "[PASS] HMAC round-trip verified successfully." -ForegroundColor Green
    } else {
        Write-Host "[FAIL] HMAC verification failed!" -ForegroundColor Red
    }
    return $valid
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($NewRecord) {
    if (-not $OldPath -or -not $NewPath) {
        Write-Error "Usage: -NewRecord -OldPath <old> -NewPath <new> [-Agent <name>] [-Reason <text>]"
        return
    }
    $rec = New-FileChangeRecord -OldFilePath $OldPath -NewFilePath $NewPath -AgentName $Agent -ChangeReason $Reason
    if ($Cascade) {
        $oldName = [System.IO.Path]::GetFileName($OldPath)
        $newName = [System.IO.Path]::GetFileName($NewPath)
        if ($oldName -ne $newName) {
            Update-WorkspaceReferences -OldName $oldName -NewName $newName
        }
    }
}
elseif ($Verify) {
    Initialize-ChangeKey
    Invoke-LedgerVerify
}
elseif ($Show) {
    Initialize-ChangeKey
    Show-ChangeLedger
}
elseif ($Test) {
    Initialize-ChangeKey
    Invoke-RoundTripTest
}
else {
    Write-Host @"
Invoke-FileChangeTracker.ps1 - Cryptographic File Change Ledger

Usage:
  -NewRecord -OldPath <old> -NewPath <new> [-Agent <name>] [-Reason <text>] [-Cascade]
  -Verify       Verify all ledger record HMAC signatures
  -Show         Display ledger with verification badges
  -Test         Run HMAC round-trip self-test

Key:    $keyPath
Ledger: $ledgerPath
"@ -ForegroundColor Cyan
}

# --- End lifecycle logging ---
if (Get-Command Write-AppLog -ErrorAction SilentlyContinue) {
    Write-AppLog -Message "Completed: $($MyInvocation.MyCommand.Name)" -Level 'Info'
}
