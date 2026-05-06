# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-WorkspaceRollback -- rollback any workspace file set to a checkpoint snapshot.
.DESCRIPTION
    Provides full workspace rollback capabilities using the checkpoint system:
      - Get-RollbackPoints          : enumerate local checkpoints + archive ZIPs
      - Invoke-RollbackToPoint      : restore workspace files from a named checkpoint
      - Test-RollbackAbility        : dry-run validation of a rollback point (pre-purge)
      - Export-RollbackArchive      : export a checkpoint or current state to a ZIP
                                      (optionally AES-256 encrypted via vault key)
      - Import-RollbackArchive      : decrypt + restore from an encrypted archive ZIP
      - Invoke-ArchiveCleanup       : validate remote ZIPs; advise which local files
                                      are safe to purge; list files restorable from
                                      manual / auto / remote archives

    Location configuration is read from config\My-LookupLocationsConfig.json.
    Each location may have a separate admin key and read-only key stored in the vault.
    Read-only access is favoured for recovery and remote ZIP scanning.

.NOTES
    Author  : The Establishment
    Date    : 2026-04-03
    FileRole: Script
    Version : 2604.B2.V31.0

.EXAMPLE
    # List available rollback points
    .\Invoke-WorkspaceRollback.ps1 -Action List

    # Export current state to LOC-001 (encrypted)
    .\Invoke-WorkspaceRollback.ps1 -Action Export -LocationId LOC-001

    # Dry-run validate a named epoch before purging local files
    .\Invoke-WorkspaceRollback.ps1 -Action TestRollback -EpochId epoch-466840aa

    # Roll back to a point
    .\Invoke-WorkspaceRollback.ps1 -Action Rollback -EpochId epoch-466840aa -WorkspacePath C:\PowerShellGUI

    # Run cleanup advisor
    .\Invoke-WorkspaceRollback.ps1 -Action Cleanup
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet('List','Export','Import','Rollback','TestRollback','Cleanup')]
    [string]$Action,

    [string]$WorkspacePath,
    [string]$EpochId,
    [string]$LocationId,
    [string]$ArchivePath,
    [switch]$DryRun,
    [switch]$Force
)

Set-StrictMode -Off

# ═══════════════════════════════════════════════════════════════════════════════
#  SETUP
# ═══════════════════════════════════════════════════════════════════════════════

if (-not $WorkspacePath) { $WorkspacePath = Split-Path $PSScriptRoot -Parent }
$checkpointsDir  = Join-Path $WorkspacePath 'checkpoints'
$configDir       = Join-Path $WorkspacePath 'config'
$locConfigPath   = Join-Path $configDir 'My-LookupLocationsConfig.json'
$vaultModulePath = Join-Path (Join-Path $WorkspacePath 'modules') 'AssistedSASC.psm1'

function Write-RbLog {
    param([string]$Message, [string]$Severity = 'Informational')
    try { Write-AppLog $Message $Severity } catch {
        $ts = Get-Date -Format 'HH:mm:ss'
        Write-Host "[$ts][RollbackRb] $Message"
    }
}

# Load vault module if available
if (Test-Path $vaultModulePath) {
    try { Import-Module $vaultModulePath -Force -ErrorAction Stop } catch {
        Write-RbLog "Vault module load warning: $($_.Exception.Message)" 'Warning'
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  LOCATION CONFIG
# ═══════════════════════════════════════════════════════════════════════════════

function Get-LocationConfig {
    <#
    .SYNOPSIS  Load My-LookupLocationsConfig.json and return enabled locations.
    #>
    [CmdletBinding()]
    param([string]$Path, [string]$FilterId)
    if (-not (Test-Path $Path)) {
        Write-RbLog "My-LookupLocationsConfig.json not found at $Path" 'Warning'
        return @()
    }
    $cfg = $null
    try {
        $cfg = Get-Content $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-RbLog "Failed to parse location config: $($_.Exception.Message)" 'Error'
        return @()
    }
    $locs = @($cfg.locations) | Where-Object { $_.enabled -eq $true }
    if ($FilterId) { $locs = @($locs) | Where-Object { $_.id -eq $FilterId } }
    return @($locs)
}

function Get-VaultKeyForLocation {
    <#
    .SYNOPSIS  Retrieve AES key from vault for a location by vault entry name.
    #>
    [CmdletBinding()]
    param([string]$VaultEntry, [switch]$ReadOnly)
    if (-not (Get-Command Get-VaultItem -ErrorAction SilentlyContinue)) {
        Write-RbLog 'Vault module not available — cannot retrieve encryption key' 'Warning'
        return $null
    }
    try {
        $item = Get-VaultItem -Name $VaultEntry -ErrorAction Stop
        if ($item -and $item.Notes) { return $item.Notes }
        Write-RbLog "Vault entry '$VaultEntry' found but Notes field is empty" 'Warning'
    } catch {
        Write-RbLog "Vault key '$VaultEntry' not found: $($_.Exception.Message)" 'Warning'
    }
    return $null
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ENCRYPTION HELPERS  (AES-256-CBC, PS 5.1 compatible)
# ═══════════════════════════════════════════════════════════════════════════════

function Protect-ArchiveBytes {
    <#
    .SYNOPSIS  AES-256-CBC encrypt byte array using Base64-encoded key string.
    #>
    [CmdletBinding()]
    param([byte[]]$Data, [string]$KeyBase64)
    $keyBytes = [Convert]::FromBase64String($KeyBase64)
    if ($keyBytes.Length -ne 32) { throw "Encryption key must be 32 bytes (AES-256)" }
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
    $aes.Key = $keyBytes; $aes.GenerateIV()
    $iv = $aes.IV
    $enc = $aes.CreateEncryptor()
    $ms  = New-Object System.IO.MemoryStream
    $cs  = New-Object System.Security.Cryptography.CryptoStream($ms, $enc, 'Write')
    try {
        $cs.Write($Data, 0, $Data.Length)
        $cs.FlushFinalBlock()
    } finally { $cs.Dispose(); $aes.Dispose() }
    # Prepend 16-byte IV to ciphertext
    $result = New-Object byte[]($iv.Length + $ms.ToArray().Length)
    [Buffer]::BlockCopy($iv, 0, $result, 0, $iv.Length)
    [Buffer]::BlockCopy($ms.ToArray(), 0, $result, $iv.Length, $ms.ToArray().Length)
    return $result
}

function Unprotect-ArchiveBytes {
    <#
    .SYNOPSIS  AES-256-CBC decrypt byte array using Base64-encoded key string.
    #>
    [CmdletBinding()]
    param([byte[]]$Data, [string]$KeyBase64)
    $keyBytes = [Convert]::FromBase64String($KeyBase64)
    if ($keyBytes.Length -ne 32) { throw "Decryption key must be 32 bytes (AES-256)" }
    $iv         = New-Object byte[] 16
    $ciphertext = New-Object byte[]($Data.Length - 16)
    [Buffer]::BlockCopy($Data, 0, $iv, 0, 16)
    [Buffer]::BlockCopy($Data, 16, $ciphertext, 0, $ciphertext.Length)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
    $aes.Key = $keyBytes; $aes.IV = $iv
    $dec = $aes.CreateDecryptor()
    $ms  = New-Object System.IO.MemoryStream
    $cs  = New-Object System.Security.Cryptography.CryptoStream($ms, $dec, 'Write')
    try {
        $cs.Write($ciphertext, 0, $ciphertext.Length)
        $cs.FlushFinalBlock()
    } finally { $cs.Dispose(); $aes.Dispose() }
    return $ms.ToArray()
}

# ═══════════════════════════════════════════════════════════════════════════════
#  GET ROLLBACK POINTS
# ═══════════════════════════════════════════════════════════════════════════════

function Get-RollbackPoints {
    <#
    .SYNOPSIS  List all available rollback points from local checkpoints and archive ZIPs.
    .OUTPUTS   [PSCustomObject[]] PointId, Label, Timestamp, Source, Path, EpochData
    #>
    [CmdletBinding()]
    param([string]$WorkspacePath, [string]$LocationId)

    $points = [System.Collections.ArrayList]::new()

    # Local epoch checkpoints
    $indexPath = Join-Path (Join-Path $WorkspacePath 'checkpoints') '_index.json'
    if (Test-Path $indexPath) {
        try {
            $index = Get-Content $indexPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $index.PSObject.Properties | ForEach-Object {
                $epochFile = Join-Path $WorkspacePath ($_.Value -replace '/', '\')
                $epochData = $null
                if (Test-Path $epochFile) {
                    try { $epochData = Get-Content $epochFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { <# Intentional: epoch file may be corrupt/invalid #> }
                }
                [void]$points.Add([PSCustomObject]@{
                    PointId   = $_.Name
                    Label     = if ($epochData -and $epochData.phase) { $epochData.phase } else { $_.Name }
                    Timestamp = if ($epochData -and $epochData.timestamp) { $epochData.timestamp } else { '' }
                    Source    = 'local-checkpoint'
                    Path      = $epochFile
                    EpochData = $epochData
                })
            }
        } catch {
            Write-RbLog "Get-RollbackPoints: failed to read checkpoint index: $($_.Exception.Message)" 'Warning'
        }
    }

    # Archive ZIPs in active locations
    $locations = Get-LocationConfig -Path (Join-Path (Join-Path $WorkspacePath 'config') 'My-LookupLocationsConfig.json') -FilterId $LocationId
    foreach ($loc in $locations) {
        if (-not (Test-Path $loc.path)) { continue }
        $archives = Get-ChildItem -Path $loc.path -Filter '*.zip' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending
        foreach ($arc in $archives) {
            [void]$points.Add([PSCustomObject]@{
                PointId   = [IO.Path]::GetFileNameWithoutExtension($arc.Name)
                Label     = $arc.Name
                Timestamp = $arc.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                Source    = "archive-$($loc.id)"
                Path      = $arc.FullName
                EpochData = $null
            })
        }
    }

    Write-RbLog "Get-RollbackPoints: found $(@($points).Count) rollback point(s)" 'Informational'
    return @($points) | Sort-Object Timestamp -Descending
}

# ═══════════════════════════════════════════════════════════════════════════════
#  EXPORT ROLLBACK ARCHIVE
# ═══════════════════════════════════════════════════════════════════════════════

function Export-RollbackArchive {
    <#
    .SYNOPSIS
        Archive the current workspace (or a checkpoint snapshot) to a ZIP,
        optionally AES-256 encrypted using the vault key for the target location.
    .PARAMETER WorkspacePath  Workspace root.
    .PARAMETER DestinationPath  Full path to output ZIP (before encryption suffix appended).
    .PARAMETER KeyBase64  Optional AES-256 key (Base64) for encryption.
    .PARAMETER DryRun  Report what would be done without writing.
    .OUTPUTS   [PSCustomObject] ArchivePath, FilesArchived, SizeBytes, Encrypted
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$DestinationPath,
        [string]$KeyBase64,
        [switch]$DryRun
    )

    [System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null

    # Collect files — exclude dot-folders, build artifacts, and large download caches
    $excludePatterns = @('.git', '.history', '.venv', '.venv-pygame312', 'node_modules', '__pycache__', '~DOWNLOADS')
    $files = Get-ChildItem -Path $WorkspacePath -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object {
                 $fp = $_.FullName
                 $relDir = $fp.Substring($WorkspacePath.Length).TrimStart('\','/')
                 # Exclude any path segment starting with a dot (generic dot-folder guard)
                 $hasDotFolder = ($relDir -split '[\\/]') | Where-Object { $_ -match '^\.' }
                 if (@($hasDotFolder).Count -gt 0) { return $false }
                 -not ($excludePatterns | Where-Object { $fp -like "*$_*" })
             }

    $fileCount = @($files).Count
    Write-RbLog "Export-RollbackArchive: $fileCount files to archive to $DestinationPath (Encrypt=$(-not [string]::IsNullOrEmpty($KeyBase64)))" 'Informational'

    if ($DryRun) {
        return [PSCustomObject]@{ ArchivePath = $DestinationPath; FilesArchived = $fileCount; SizeBytes = 0; Encrypted = $false; DryRun = $true }
    }

    $destDir = Split-Path $DestinationPath -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    $tempZip = [IO.Path]::ChangeExtension($DestinationPath, '.tmp.zip')
    try {
        # Build zip file-by-file respecting the exclusion filter (CreateFromDirectory ignores it)
        $zipMode = [System.IO.Compression.ZipArchiveMode]::Create
        $zipStream = [System.IO.File]::Open($tempZip, [System.IO.FileMode]::Create)
        $archive = New-Object System.IO.Compression.ZipArchive($zipStream, $zipMode)
        foreach ($f in $files) {
            $entryName = $f.FullName.Substring($WorkspacePath.Length).TrimStart('\','/')
            $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            $fileStream = [System.IO.File]::OpenRead($f.FullName)
            try { $fileStream.CopyTo($entryStream) } finally { $fileStream.Close(); $entryStream.Close() }
        }
        $archive.Dispose()
        $zipStream.Close()
    } catch {
        Write-RbLog "Export-RollbackArchive: ZIP creation failed: $($_.Exception.Message)" 'Error'
        throw
    }

    $zipBytes  = [IO.File]::ReadAllBytes($tempZip)
    $zipSize   = $zipBytes.Length
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue

    if ($KeyBase64) {
        $encPath  = $DestinationPath -replace '\.zip$', '.enc.zip'
        $encBytes = Protect-ArchiveBytes -Data $zipBytes -KeyBase64 $KeyBase64
        [IO.File]::WriteAllBytes($encPath, $encBytes)
        Write-RbLog "Export-RollbackArchive: encrypted archive written to $encPath ($([math]::Round($encBytes.Length/1KB,1)) KB)" 'Informational'
        return [PSCustomObject]@{ ArchivePath = $encPath; FilesArchived = $fileCount; SizeBytes = $encBytes.Length; Encrypted = $true; DryRun = $false }
    } else {
        [IO.File]::WriteAllBytes($DestinationPath, $zipBytes)
        Write-RbLog "Export-RollbackArchive: plain archive written to $DestinationPath ($([math]::Round($zipSize/1KB,1)) KB)" 'Informational'
        return [PSCustomObject]@{ ArchivePath = $DestinationPath; FilesArchived = $fileCount; SizeBytes = $zipSize; Encrypted = $false; DryRun = $false }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  IMPORT (RESTORE) ROLLBACK ARCHIVE
# ═══════════════════════════════════════════════════════════════════════════════

function Import-RollbackArchive {
    <#
    .SYNOPSIS
        Decrypt (if encrypted) and restore files from a rollback archive ZIP.
    .PARAMETER ArchivePath  Path to the .zip or .enc.zip archive.
    .PARAMETER DestinationPath  Directory to restore into.
    .PARAMETER KeyBase64  AES-256 key (Base64) if archive is encrypted.
    .PARAMETER DryRun  List files that would be restored without writing.
    .OUTPUTS   [PSCustomObject] RestoredFiles, SizeBytes, Success
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ArchivePath,
        [Parameter(Mandatory)] [string]$DestinationPath,
        [string]$KeyBase64,
        [switch]$DryRun
    )

    [System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null

    if (-not (Test-Path $ArchivePath)) {
        Write-RbLog "Import-RollbackArchive: archive not found at $ArchivePath" 'Error'
        return [PSCustomObject]@{ RestoredFiles = 0; SizeBytes = 0; Success = $false; Error = 'Archive not found' }
    }

    $rawBytes = [IO.File]::ReadAllBytes($ArchivePath)
    $zipBytes = $rawBytes

    # Decrypt if encrypted archive
    if ($ArchivePath -match '\.enc\.zip$') {
        if (-not $KeyBase64) {
            Write-RbLog 'Import-RollbackArchive: archive is encrypted but no key provided' 'Error'
            return [PSCustomObject]@{ RestoredFiles = 0; SizeBytes = 0; Success = $false; Error = 'No decryption key provided' }
        }
        try {
            $zipBytes = Unprotect-ArchiveBytes -Data $rawBytes -KeyBase64 $KeyBase64
        } catch {
            Write-RbLog "Import-RollbackArchive: decryption failed: $($_.Exception.Message)" 'Error'
            return [PSCustomObject]@{ RestoredFiles = 0; SizeBytes = 0; Success = $false; Error = $_.Exception.Message }
        }
    }

    $tempZip = [IO.Path]::Combine([IO.Path]::GetTempPath(), "rollback-restore-$(Get-Date -Format 'yyyyMMddHHmmss').zip")
    try {
        [IO.File]::WriteAllBytes($tempZip, $zipBytes)
        if ($DryRun) {
            # List entries only
            $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
            $entries    = @($zipArchive.Entries)
            $zipArchive.Dispose()
            Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
            Write-RbLog "Import-RollbackArchive (DryRun): would restore $(@($entries).Count) files" 'Informational'
            return [PSCustomObject]@{ RestoredFiles = @($entries).Count; SizeBytes = $zipBytes.Length; Success = $true; DryRun = $true }
        }

        if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($tempZip, $DestinationPath)
        Write-RbLog "Import-RollbackArchive: extracted to $DestinationPath" 'Informational'
        return [PSCustomObject]@{ RestoredFiles = -1; SizeBytes = $zipBytes.Length; Success = $true; DryRun = $false }
    } catch {
        Write-RbLog "Import-RollbackArchive: extraction failed: $($_.Exception.Message)" 'Error'
        return [PSCustomObject]@{ RestoredFiles = 0; SizeBytes = 0; Success = $false; Error = $_.Exception.Message }
    } finally {
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  TEST ROLLBACK ABILITY
# ═══════════════════════════════════════════════════════════════════════════════

function Test-RollbackAbility {
    <#
    .SYNOPSIS
        Validate that a rollback point is restorable before local files are purged.
    .DESCRIPTION
        For archive ZIPs: opens and reads the ZIP entry list to confirm the archive
        is readable and non-empty.
        For local checkpoints: verifies the epoch JSON is parseable and the phase
        and versionState fields are populated.
    .PARAMETER PointId  Rollback point ID from Get-RollbackPoints.
    .PARAMETER WorkspacePath  Workspace root.
    .OUTPUTS   [PSCustomObject] Restorable [bool], EntryCount, PointId, Notes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PointId,
        [Parameter(Mandatory)] [string]$WorkspacePath
    )

    $points = Get-RollbackPoints -WorkspacePath $WorkspacePath
    $point  = $points | Where-Object { $_.PointId -eq $PointId } | Select-Object -First 1

    if (-not $point) {
        return [PSCustomObject]@{ Restorable = $false; EntryCount = 0; PointId = $PointId; Notes = 'Point not found' }
    }

    if ($point.Source -like 'archive-*') {
        [System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null
        try {
            $zp = [System.IO.Compression.ZipFile]::OpenRead($point.Path)
            $count = @($zp.Entries).Count
            $zp.Dispose()
            if ($count -gt 0) {
                return [PSCustomObject]@{ Restorable = $true; EntryCount = $count; PointId = $PointId; Notes = "Archive readable; $count entries" }
            } else {
                return [PSCustomObject]@{ Restorable = $false; EntryCount = 0; PointId = $PointId; Notes = 'Archive is empty' }
            }
        } catch {
            return [PSCustomObject]@{ Restorable = $false; EntryCount = 0; PointId = $PointId; Notes = "Archive open failed: $($_.Exception.Message)" }
        }
    } else {
        # Local checkpoint
        $epoch = $point.EpochData
        if ($epoch -and $epoch.phase -and $epoch.versionState) {
            return [PSCustomObject]@{ Restorable = $true; EntryCount = 1; PointId = $PointId; Notes = "Epoch: $($epoch.phase) v$($epoch.versionState.fullTag)" }
        } else {
            return [PSCustomObject]@{ Restorable = $false; EntryCount = 0; PointId = $PointId; Notes = 'Epoch JSON malformed or missing versionState' }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ARCHIVE CLEANUP ADVISOR
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-ArchiveCleanup {
    <#
    .SYNOPSIS
        Validate remote archive ZIPs and advise which local checkpoint files are
        safe to purge or already restorable from remote.
    .DESCRIPTION
        For each enabled location:
          1. Connects (if reachable) and opens each archive ZIP to verify readability.
          2. Cross-references local checkpoint IDs with remote archive file names.
          3. Reports: validated remote ZIPs, local checkpoints also in remote,
             and local files that have NO remote backup (keep locally).
    .PARAMETER WorkspacePath  Workspace root.
    .OUTPUTS   [PSCustomObject] with RemoteZipsValidated, SafeToPurge, MustKeepLocal,
               RestorableFromRemote, ValidationErrors
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    [System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null

    $locations     = Get-LocationConfig -Path (Join-Path (Join-Path $WorkspacePath 'config') 'My-LookupLocationsConfig.json')
    $localPoints   = @(Get-RollbackPoints -WorkspacePath $WorkspacePath | Where-Object { $_.Source -eq 'local-checkpoint' })
    $localIds      = @($localPoints | ForEach-Object { $_.PointId })

    $remoteValidated   = [System.Collections.ArrayList]::new()
    $validationErrors  = [System.Collections.ArrayList]::new()
    $remoteIdsFound    = [System.Collections.ArrayList]::new()

    foreach ($loc in $locations) {
        if ($loc.type -notin @('remote-unc') -and -not $loc.remoteValidation.enabled) { continue }
        if (-not (Test-Path $loc.path)) {
            [void]$validationErrors.Add("Location $($loc.id) ($($loc.label)) not reachable at $($loc.path)")
            continue
        }
        $zips = Get-ChildItem -Path $loc.path -Filter '*.zip' -ErrorAction SilentlyContinue
        foreach ($zip in $zips) {
            $entry = [PSCustomObject]@{
                LocationId = $loc.id
                ZipPath    = $zip.FullName
                EntryCount = 0
                Valid      = $false
                Error      = $null
            }
            try {
                $za = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
                $entry.EntryCount = @($za.Entries).Count
                $za.Dispose()
                $entry.Valid = ($entry.EntryCount -gt 0)
                # Track matching checkpoint IDs
                $baseName = [IO.Path]::GetFileNameWithoutExtension($zip.Name) -replace '\.enc$', ''
                if ($localIds -contains $baseName) { [void]$remoteIdsFound.Add($baseName) }
                [void]$remoteValidated.Add($entry)
            } catch {
                $entry.Error = $_.Exception.Message
                [void]$validationErrors.Add("ZIP validate error $($zip.Name): $($_.Exception.Message)")
                [void]$remoteValidated.Add($entry)
            }
        }
    }

    $safeToPurge  = @($localPoints | Where-Object { $remoteIdsFound -contains $_.PointId })
    $mustKeep     = @($localPoints | Where-Object { $remoteIdsFound -notcontains $_.PointId })

    Write-RbLog "Invoke-ArchiveCleanup: $(@($remoteValidated).Count) remote ZIPs validated. SafeToPurge=$(@($safeToPurge).Count) MustKeepLocal=$(@($mustKeep).Count)" 'Informational'

    [PSCustomObject]@{
        RemoteZipsValidated   = @($remoteValidated)
        SafeToPurge           = @($safeToPurge)
        MustKeepLocal         = @($mustKeep)
        RestorableFromRemote  = @($remoteIdsFound)
        ValidationErrors      = @($validationErrors)
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ROLLBACK TO POINT  (partial restore of workspace metadata / epoch state)
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-RollbackToPoint {
    <#
    .SYNOPSIS
        Restore workspace state from a named rollback point.
    .DESCRIPTION
        For archive ZIPs: extracts into a new timestamped restore directory under
        ~DOWNLOADS/rollback-restore-* to avoid destructive overwrites.
        Use -Force to overwrite directly into WorkspacePath (dangerous).
        For local epoch checkpoints: displays the epoch metadata and version state
        as a reference; does NOT auto-revert source files (would need git or full ZIP).
    .PARAMETER PointId  ID from Get-RollbackPoints.
    .PARAMETER WorkspacePath  Workspace root.
    .PARAMETER Force  Overwrite workspace files directly (destructive).
    .PARAMETER DryRun  List what would be restored without changes.
    .OUTPUTS   [PSCustomObject] Success, Action, TargetPath, Notes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PointId,
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [switch]$Force,
        [switch]$DryRun
    )

    $points = Get-RollbackPoints -WorkspacePath $WorkspacePath
    $point  = $points | Where-Object { $_.PointId -eq $PointId } | Select-Object -First 1

    if (-not $point) {
        return [PSCustomObject]@{ Success = $false; Action = 'None'; TargetPath = ''; Notes = "Point '$PointId' not found" }
    }

    $ability = Test-RollbackAbility -PointId $PointId -WorkspacePath $WorkspacePath
    if (-not $ability.Restorable) {
        return [PSCustomObject]@{ Success = $false; Action = 'None'; TargetPath = ''; Notes = "Point not restorable: $($ability.Notes)" }
    }

    if ($point.Source -eq 'local-checkpoint') {
        # Epoch checkpoints are metadata only — provide actionable guidance
        $msg = "Epoch checkpoint '$PointId' ($($point.Label)) — version $($point.EpochData.versionState.fullTag) at $($point.Timestamp). " +
               "No file-level restore — use an archive ZIP export from this epoch or git history."
        Write-RbLog $msg 'Informational'
        return [PSCustomObject]@{ Success = $true; Action = 'MetadataOnly'; TargetPath = $point.Path; Notes = $msg }
    }

    # Archive ZIP restore
    $targetDir = if ($Force) {
        $WorkspacePath
    } else {
        Join-Path (Join-Path $WorkspacePath '~DOWNLOADS') ("rollback-restore-$PointId-$(Get-Date -Format 'yyyyMMddHHmmss')")
    }

    $result = Import-RollbackArchive -ArchivePath $point.Path -DestinationPath $targetDir -DryRun:$DryRun
    if ($result.Success) {
        Write-RbLog "Invoke-RollbackToPoint: restored '$PointId' to $targetDir" 'Informational'
    } else {
        Write-RbLog "Invoke-RollbackToPoint: restore failed — $($result.Error)" 'Error'
    }

    [PSCustomObject]@{
        Success    = $result.Success
        Action     = if ($DryRun) { 'DryRun' } elseif ($Force) { 'DirectOverwrite' } else { 'RestoredToSubfolder' }
        TargetPath = $targetDir
        Notes      = if ($result.Error) { $result.Error } else { "Restored $($result.RestoredFiles) entries" }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN DISPATCH
# ═══════════════════════════════════════════════════════════════════════════════

switch ($Action) {
    'List' {
        $pts = Get-RollbackPoints -WorkspacePath $WorkspacePath -LocationId $LocationId
        if (@($pts).Count -eq 0) {
            Write-Host "No rollback points found."
        } else {
            $pts | Format-Table PointId, Label, Timestamp, Source -AutoSize
        }
    }
    'Export' {
        $loc = Get-LocationConfig -Path $locConfigPath -FilterId $LocationId | Select-Object -First 1
        if (-not $loc) { Write-Host "Location '$LocationId' not found or not enabled."; exit 1 }
        $keyB64  = Get-VaultKeyForLocation -VaultEntry $loc.adminKeyVaultEntry
        $outName = "rollback-$(Get-Date -Format 'yyyyMMdd-HHmmss').zip"
        $outPath = Join-Path $loc.path $outName
        $result  = Export-RollbackArchive -WorkspacePath $WorkspacePath -DestinationPath $outPath -KeyBase64 $keyB64 -DryRun:$DryRun
        $result | Format-List
    }
    'Import' {
        if (-not $ArchivePath) { Write-Host "Specify -ArchivePath for Import action."; exit 1 }
        $loc    = Get-LocationConfig -Path $locConfigPath -FilterId $LocationId | Select-Object -First 1
        $keyB64 = if ($loc) { Get-VaultKeyForLocation -VaultEntry $loc.readOnlyKeyVaultEntry } else { $null }
        $result = Import-RollbackArchive -ArchivePath $ArchivePath -DestinationPath $WorkspacePath -KeyBase64 $keyB64 -DryRun:$DryRun
        $result | Format-List
    }
    'TestRollback' {
        if (-not $EpochId) { Write-Host "Specify -EpochId for TestRollback action."; exit 1 }
        $result = Test-RollbackAbility -PointId $EpochId -WorkspacePath $WorkspacePath
        $result | Format-List
    }
    'Rollback' {
        if (-not $EpochId) { Write-Host "Specify -EpochId for Rollback action."; exit 1 }
        $result = Invoke-RollbackToPoint -PointId $EpochId -WorkspacePath $WorkspacePath -Force:$Force -DryRun:$DryRun
        $result | Format-List
    }
    'Cleanup' {
        $result = Invoke-ArchiveCleanup -WorkspacePath $WorkspacePath
        Write-Host "`nRemote ZIPs validated: $(@($result.RemoteZipsValidated).Count)"
        Write-Host "Safe to purge locally: $(@($result.SafeToPurge).Count)"
        Write-Host "Must keep locally:     $(@($result.MustKeepLocal).Count)"
        Write-Host "`n--- Safe to Purge ---"
        @($result.SafeToPurge) | Format-Table PointId, Label, Timestamp -AutoSize
        Write-Host "`n--- Must Keep Local (no remote backup) ---"
        @($result.MustKeepLocal) | Format-Table PointId, Label, Timestamp -AutoSize
        if (@($result.ValidationErrors).Count -gt 0) {
            Write-Host "`n--- Validation Errors ---"
            $result.ValidationErrors | ForEach-Object { Write-Warning $_ }
        }
    }
}

