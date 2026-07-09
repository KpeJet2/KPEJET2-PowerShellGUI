# VersionTag: 2606.B5.V51.4
# PwShGUI-WorkspaceSeed.psm1 — Workspace seeding and initialization module

Set-StrictMode -Version Latest

<#
.SYNOPSIS
Finds candidate seed packages from fallback locations or user selection.

.DESCRIPTION
Searches standard fallback paths (%appdata%\PowershellGUI, c:\PowershellGUI, C:\TEMP\PowershellGUI)
for ZIP files or folder backups that can be used to seed a new workspace.

.OUTPUTS
[PSCustomObject] with properties: Path, Type (ZIP|Folder), Modified, SizeGB
#>
function Find-SeedPath {
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $PSScriptRoot,
        [string[]]$FallbackSearchPaths
    )

    $results = [System.Collections.ArrayList]@()

    if ($null -eq $FallbackSearchPaths -or @($FallbackSearchPaths).Count -eq 0) {
        $FallbackSearchPaths = @(
            [Environment]::ExpandEnvironmentVariables('%appdata%\PowershellGUI'),
            'c:\PowershellGUI',
            'C:\TEMP\PowershellGUI'
        )
    }

    foreach ($searchPath in $FallbackSearchPaths) {
        $expanded = [Environment]::ExpandEnvironmentVariables($searchPath)
        
        if (-not (Test-Path -LiteralPath $expanded)) { continue }

        try {
            # Scan for ZIP files
            $zipFiles = @(Get-ChildItem -LiteralPath $expanded -Filter '*.zip' -File -ErrorAction Stop)
            foreach ($zip in $zipFiles) {
                [void]$results.Add([PSCustomObject]@{
                    Path = $zip.FullName
                    Type = 'ZIP'
                    Modified = $zip.LastWriteTime
                    SizeGB = [Math]::Round($zip.Length / 1GB, 2)
                    FileName = $zip.Name
                })
            }

            # Scan for folder backups (e.g., "PowerShellGUI-backup-*")
            $folderCandidates = @(Get-ChildItem -LiteralPath $expanded -Directory -Filter '*backup*' -ErrorAction Stop)
            foreach ($folder in $folderCandidates) {
                $size = @(Get-ChildItem -LiteralPath $folder.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                [void]$results.Add([PSCustomObject]@{
                    Path = $folder.FullName
                    Type = 'Folder'
                    Modified = $folder.LastWriteTime
                    SizeGB = [Math]::Round($size / 1GB, 2)
                    FileName = $folder.Name
                })
            }
        } catch {
            Write-Verbose "Error scanning $expanded : $_"
        }
    }

    return @($results | Sort-Object -Property Modified -Descending)
}

<#
.SYNOPSIS
Expands a seed package (ZIP or folder) to the target workspace.

.DESCRIPTION
Extracts or copies seed contents, optionally preserving existing local files based on preserve list.

.PARAMETER SeedPath
Path to ZIP file or source folder

.PARAMETER TargetPath
Destination workspace path

.PARAMETER PreservePatterns
File patterns to preserve (e.g., 'config/*.json', 'logs/*')

.OUTPUTS
[PSCustomObject] with properties: Success, ExtractedFileCount, PreservedFileCount, Errors
#>
function Expand-SeedPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SeedPath,
        [Parameter(Mandatory)] [string]$TargetPath,
        [string[]]$PreservePatterns
    )

    $result = [PSCustomObject]@{
        Success = $false
        ExtractedFileCount = 0
        PreservedFileCount = 0
        Errors = @()
        WarningMessages = @()
    }

    if (-not (Test-Path -LiteralPath $SeedPath)) {
        $result.Errors += "Seed path not found: $SeedPath"
        return $result
    }

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        try {
            $null = New-Item -ItemType Directory -Path $TargetPath -Force -ErrorAction Stop
        } catch {
            $result.Errors += "Failed to create target path: $_"
            return $result
        }
    }

    $isZip = $SeedPath -like '*.zip'

    try {
        if ($isZip) {
            # Extract ZIP using System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
            $zip = [System.IO.Compression.ZipFile]::OpenRead($SeedPath)
            
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName -eq '' -or $entry.FullName.EndsWith('/')) { continue }
                
                $targetFile = Join-Path $TargetPath $entry.FullName
                $targetDir = Split-Path $targetFile -Parent
                
                if (-not (Test-Path -LiteralPath $targetDir)) {
                    $null = New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop
                }

                # Check if file matches preserve patterns
                $shouldPreserve = $false
                if ($PreservePatterns) {
                    foreach ($pattern in $PreservePatterns) {
                        if ([System.Management.Automation.WildcardPattern]::new($pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($entry.FullName)) {
                            $shouldPreserve = $true
                            break
                        }
                    }
                }

                if ($shouldPreserve -and (Test-Path -LiteralPath $targetFile)) {
                    $result.PreservedFileCount += 1
                } else {
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetFile, $true)
                    $result.ExtractedFileCount += 1
                }
            }

            $zip.Dispose()
        } else {
            # Copy from folder
            $sourceItems = @(Get-ChildItem -LiteralPath $SeedPath -Recurse -File -ErrorAction Stop)
            foreach ($item in $sourceItems) {
                $relativePath = $item.FullName.Substring($SeedPath.Length).TrimStart('\')
                $targetFile = Join-Path $TargetPath $relativePath
                $targetDir = Split-Path $targetFile -Parent

                if (-not (Test-Path -LiteralPath $targetDir)) {
                    $null = New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop
                }

                # Check preserve patterns
                $shouldPreserve = $false
                if ($PreservePatterns) {
                    foreach ($pattern in $PreservePatterns) {
                        if ([System.Management.Automation.WildcardPattern]::new($pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($relativePath)) {
                            $shouldPreserve = $true
                            break
                        }
                    }
                }

                if ($shouldPreserve -and (Test-Path -LiteralPath $targetFile)) {
                    $result.PreservedFileCount += 1
                } else {
                    Copy-Item -LiteralPath $item.FullName -Destination $targetFile -Force -ErrorAction Stop
                    $result.ExtractedFileCount += 1
                }
            }
        }

        $result.Success = $true
    } catch {
        $result.Errors += "Extraction failed: $_"
    }

    return $result
}

<#
.SYNOPSIS
Registers tray service to auto-start via scheduled task or registry.

.DESCRIPTION
Creates a scheduled task (SYSTEM context) or registry RunOnce entry to launch the tray service
on next system startup.

.PARAMETER Method
'ScheduledTask' or 'Registry' (default: ScheduledTask)

.OUTPUTS
[PSCustomObject] with properties: Success, Method, Path, Errors
#>
function Register-TrayAutoStart {
    [CmdletBinding()]
    param(
        [ValidateSet('ScheduledTask', 'Registry')] [string]$Method = 'ScheduledTask',
        [string]$TrayScriptPath = (Join-Path $PSScriptRoot 'scripts\Start-LocalWebEngineService.ps1'),
        [string]$Port = '8042'
    )

    $result = [PSCustomObject]@{
        Success = $false
        Method = $Method
        Path = $null
        Errors = @()
    }

    if (-not (Test-Path -LiteralPath $TrayScriptPath)) {
        $result.Errors += "Tray script not found: $TrayScriptPath"
        return $result
    }

    try {
        if ($Method -eq 'ScheduledTask') {
            $taskName = 'PowerShellGUI-TrayAutoStart'
            $taskDescription = 'Auto-start PowerShell GUI Tray Service on system startup'
            
            # Remove existing task if present
            try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }

            # Create task action
            $action = New-ScheduledTaskAction `
                -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$TrayScriptPath`" -Action RunTray -Port $Port" `
                -ErrorAction Stop

            # Create task trigger (at startup)
            $trigger = New-ScheduledTaskTrigger -AtStartup -ErrorAction Stop

            # Register task
            $task = Register-ScheduledTask `
                -TaskName $taskName `
                -Action $action `
                -Trigger $trigger `
                -Description $taskDescription `
                -RunLevel Highest `
                -Force `
                -ErrorAction Stop

            $result.Success = $true
            $result.Path = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\$taskName"
        } else {
            # Registry method (RunOnce)
            $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
            $valueName = 'PowerShellGUI-Tray'
            $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$TrayScriptPath`" -Action RunTray -Port $Port"

            if (-not (Test-Path -LiteralPath $regPath)) {
                $null = New-Item -Path $regPath -Force -ErrorAction Stop
            }

            Set-ItemProperty -LiteralPath $regPath -Name $valueName -Value $command -ErrorAction Stop
            $result.Success = $true
            $result.Path = "$regPath\$valueName"
        }
    } catch {
        $result.Errors += "Registration failed: $_"
    }

    return $result
}

<#
.SYNOPSIS
Detects if workspace needs seeding (incomplete/empty).

.DESCRIPTION
Checks for critical workspace files/folders. Returns $true if seeding is recommended.

.OUTPUTS
[bool]
#>
function Test-WorkspaceNeedsSeeding {
    [CmdletBinding()]
    param(
        [string]$WorkspacePath = $PSScriptRoot
    )

    $criticalPaths = @(
        'config\pwsh-app-config-BASE.json',
        'modules\PwShGUI-TrayHost.psm1',
        'scripts\Start-LocalWebEngine.ps1'
    )

    foreach ($path in $criticalPaths) {
        $fullPath = Join-Path $WorkspacePath $path
        if (-not (Test-Path -LiteralPath $fullPath)) {
            return $true
        }
    }

    return $false
}

Export-ModuleMember -Function @(
    'Find-SeedPath',
    'Expand-SeedPackage',
    'Register-TrayAutoStart',
    'Test-WorkspaceNeedsSeeding'
)


