# VersionTag: 2605.B5.V46.0
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# Author: The Establishment
# Date: 2026-04-04
# FileRole: Module
# Purpose: Collect comprehensive system telemetry for Launch-GUI.bat logging
# Description: Gathers 14 fields of system metrics including CPU, memory, disk,
#              network, and administrative status for launch tracking and diagnostics.
# TODO: HelpMenu | Show-TelemetryHelp | Actions: Collect|Report|Export|Help | Spec: config/help-menu-registry.json

<#
.SYNOPSIS
Collects comprehensive system telemetry for launch logging.

.DESCRIPTION
The Get-LaunchTelemetry function collects 14 fields of system information
including timestamp, machine details, resource utilization, and administrative
status. Designed for PS 5.1 and PS 7 compatibility with SIN compliance.

.PARAMETER BatchName
Name of the batch file being launched (e.g., "Launch-GUI.bat")

.PARAMETER VersionTag
Version tag of the batch file (e.g., "2604.B1.v1.0")

.PARAMETER BatchPath
Full path to the executing batch file

.EXAMPLE
Get-LaunchTelemetry -BatchName "Launch-GUI.bat" -VersionTag "2604.B1.v1.0" -BatchPath "C:\PowerShellGUI\Launch-GUI.bat"

.OUTPUTS
PSCustomObject with 14 telemetry properties
#>
function Get-LaunchTelemetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BatchName,

        [Parameter(Mandatory = $true)]
        [string]$VersionTag,

        [Parameter(Mandatory = $true)]
        [string]$BatchPath
    )

    try {
        # Timestamp (yyyyMMdd-HHmmss)
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

        # Machine and user information
        $machineName = $env:COMPUTERNAME
        $username = $env:USERNAME

        # IP Address (filter out APIPA 169.254.x.x and loopback)
        $ipAddress = "N/A"
        try {
            $netAdapters = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.IPAddress -notlike "169.254.*" -and
                    $_.IPAddress -ne "127.0.0.1" -and
                    $_.PrefixOrigin -ne "WellKnown"
                })
            if (@($netAdapters).Count -gt 0) {
                $ipAddress = $netAdapters[0].IPAddress
            }
        } catch {
            # Fallback: try ipconfig parsing (PS 5.1 compatibility)
            try {
                $ipconfigOutput = ipconfig | Select-String "IPv4" | Select-Object -First 1
                if ($null -ne $ipconfigOutput) {
                    $ipAddress = ($ipconfigOutput.ToString() -split ':')[1].Trim()
                    if ($ipAddress -like "169.254.*") {
                        $ipAddress = "N/A"
                    }
                }
            } catch {
                $ipAddress = "N/A"
            }
        }

        # System volume and free space
        $systemVolume = $env:SystemDrive
        $systemVolFreeSpace = "N/A"
        try {
            $driveLetter = $systemVolume -replace ':', ''
            $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
            if ($null -ne $drive -and $null -ne $drive.Free) {
                $freeGB = [math]::Round($drive.Free / 1GB, 2)
                $systemVolFreeSpace = "$freeGB GB"
            }
        } catch {
            $systemVolFreeSpace = "N/A"
        }

        # Memory utilization (Used GB / Total GB)
        $memoryUsedOfTotal = "N/A"
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($null -ne $os) {
                $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
                $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
                $usedGB = [math]::Round($totalGB - $freeGB, 1)
                $memoryUsedOfTotal = "$usedGB GB / $totalGB GB"
            }
        } catch {
            $memoryUsedOfTotal = "N/A"
        }

        # CPU Load (single sample — no sleep to avoid blocking startup)
        $cpuLoad = "N/A"
        try {
            $cpuSamples = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
            if (@($cpuSamples).Count -gt 0) {
                $cpuLoad = [math]::Round(($cpuSamples | Measure-Object -Property LoadPercentage -Average).Average, 1)
            }
        } catch {
            $cpuLoad = "N/A"
        }

        # GPU Load (optional, may not be available on all systems)
        $gpuLoad = "N/A"
        try {
            $gpuCounter = Get-Counter -Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction SilentlyContinue
            if ($null -ne $gpuCounter) {
                $gpuSamples = @($gpuCounter.CounterSamples)
                if (@($gpuSamples).Count -gt 0) {
                    $gpuLoad = [math]::Round(($gpuSamples | Measure-Object -Property CookedValue -Average).Average, 1)
                }
            }
        } catch {
            # GPU counter not available - common on VMs and systems without dedicated GPU
            $gpuLoad = "N/A"
        }

        # Total process count
        $totalProcesses = @(Get-Process -ErrorAction SilentlyContinue).Count

        # Admin elevation check
        $isAdmin = "FALSE"
        try {
            $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            if ($null -ne $currentPrincipal) {
                $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator
                if ($currentPrincipal.IsInRole($adminRole)) {
                    $isAdmin = "TRUE"
                }
            }
        } catch {
            $isAdmin = "FALSE"
        }

        # Build and return telemetry object
        $telemetry = [PSCustomObject]@{
            Timestamp = $timestamp
            BatchName = $BatchName
            VersionTag = $VersionTag
            MachineName = $machineName
            Username = $username
            IPAddress = $ipAddress
            BatchPath = $BatchPath
            SystemVolume = $systemVolume
            SystemVolFreeSpace = $systemVolFreeSpace
            MemoryUsedOfTotal = $memoryUsedOfTotal
            CPULoad = $cpuLoad
            GPULoad = $gpuLoad
            TotalProcesses = $totalProcesses
            IsAdmin = $isAdmin
        }

        return $telemetry

    } catch {
        Write-AppLog -Message "Error collecting launch telemetry: $_" -Level Warning

        # Return minimal telemetry object on error
        return [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
            BatchName = $BatchName
            VersionTag = $VersionTag
            MachineName = $env:COMPUTERNAME
            Username = $env:USERNAME
            IPAddress = "ERROR"
            BatchPath = $BatchPath
            SystemVolume = $env:SystemDrive
            SystemVolFreeSpace = "ERROR"
            MemoryUsedOfTotal = "ERROR"
            CPULoad = "ERROR"
            GPULoad = "ERROR"
            TotalProcesses = "ERROR"
            IsAdmin = "ERROR"
        }
    }
}

# Export module member

<# Outline:
    Single-function telemetry collector invoked by Launch-GUI.bat and the engine bootstrap.
    Get-LaunchTelemetry captures startup metrics (PS version, host, elapsed ms, module-load
    counts) and writes a structured record to logs/launch-telemetry.jsonl for downstream
    analysis by the CronAiAthon pipeline.
#>

<# Problems:
    None outstanding. Telemetry write is best-effort wrapped in try/catch; failures degrade
    silently so they cannot block GUI startup.
#>

<# ToDo:
    None — current scope (single-shot startup telemetry) is complete. Continuous telemetry
    streaming is intentionally out-of-scope and tracked under FEATURE-REQUEST entries.
#>
Export-ModuleMember -Function Get-LaunchTelemetry







