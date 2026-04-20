# VersionTag: 2604.B2.V31.0
# FileRole: Pipeline
# Author: The Establishment
# Date: 2026-04-04
# FileRole: Guide
# Purpose: Generate comprehensive HTML system diagnostic report
# Description: Collects OS, hardware, network, PowerShell, and module information
#              and exports to an HTML report in ~REPORTS directory.

<#
.SYNOPSIS
Generates a comprehensive HTML system diagnostic report.

.DESCRIPTION
Collects detailed system information including:
- Operating System details
- Computer hardware (CPU, RAM, disk)
- Network adapters and configuration
- Installed PowerShell modules
- Execution policy settings
- PowerShell version information

The report is saved to ~REPORTS/SystemReport_YYYYMMDD-HHMMSS.html and optionally
opened in the default browser.

.PARAMETER SkipBrowserOpen
If specified, does not automatically open the report in a browser after generation.

.EXAMPLE
.\Export-SystemReport.ps1

.EXAMPLE
.\Export-SystemReport.ps1 -SkipBrowserOpen

.OUTPUTS
HTML file saved to ~REPORTS/SystemReport_YYYYMMDD-HHMMSS.html
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$SkipBrowserOpen
)

Write-Host "`n╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  PowerShellGUI - System Report Generator                         ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Determine paths
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$workspaceRoot = Split-Path -Parent $scriptRoot
$reportsDir = Join-Path $workspaceRoot "~REPORTS"

# Ensure reports directory exists
if (-not (Test-Path -Path $reportsDir)) {
    New-Item -Path $reportsDir -ItemType Directory -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $reportsDir "SystemReport_$timestamp.html"

Write-Host "[1/7] Collecting OS information..." -NoNewline
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $osInfo = @{
        Caption = $os.Caption
        Version = $os.Version
        Architecture = $os.OSArchitecture
        BuildNumber = $os.BuildNumber
        InstallDate = $os.InstallDate
        LastBootTime = $os.LastBootUpTime
    }
    Write-Host " ✓" -ForegroundColor Green
} catch {
    $osInfo = @{ Error = $_.Exception.Message }
    Write-Host " ✗" -ForegroundColor Red
}

Write-Host "[2/7] Collecting computer system info..." -NoNewline
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $csInfo = @{
        Name = $cs.Name
        Domain = $cs.Domain
        Manufacturer = $cs.Manufacturer
        Model = $cs.Model
        TotalPhysicalMemory = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        NumberOfProcessors = $cs.NumberOfProcessors
        NumberOfLogicalProcessors = $cs.NumberOfLogicalProcessors
    }
    Write-Host " ✓" -ForegroundColor Green
} catch {
    $csInfo = @{ Error = $_.Exception.Message }
    Write-Host " ✗" -ForegroundColor Red
}

Write-Host "[3/7] Collecting processor info..." -NoNewline
try {
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
    $cpuInfo = @($processors | ForEach-Object {
        @{
            Name = $_.Name
            Cores = $_.NumberOfCores
            LogicalProcessors = $_.NumberOfLogicalProcessors
            MaxClockSpeed = $_.MaxClockSpeed
        }
    })
    Write-Host " ✓" -ForegroundColor Green
} catch {
    $cpuInfo = @(@{ Error = $_.Exception.Message })
    Write-Host " ✗" -ForegroundColor Red
}

Write-Host "[4/7] Collecting disk info..." -NoNewline
try {
    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop)
    $diskInfo = @($disks | ForEach-Object {
        @{
            DeviceID = $_.DeviceID
            VolumeName = $_.VolumeName
            FileSystem = $_.FileSystem
            SizeGB = if ($null -ne $_.Size) { [math]::Round($_.Size / 1GB, 2) } else { "N/A" }
            FreeGB = if ($null -ne $_.FreeSpace) { [math]::Round($_.FreeSpace / 1GB, 2) } else { "N/A" }
        }
    })
    Write-Host " ✓" -ForegroundColor Green
} catch {
    $diskInfo = @(@{ Error = $_.Exception.Message })
    Write-Host " ✗" -ForegroundColor Red
}

Write-Host "[5/7] Collecting network adapter info..." -NoNewline
try {
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    $netInfo = @($adapters | ForEach-Object {
        $ipConfig = Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        @{
            Name = $_.Name
            Status = $_.Status
            LinkSpeed = $_.LinkSpeed
            MacAddress = $_.MacAddress
            IPv4Address = if ($null -ne $ipConfig) { $ipConfig.IPAddress } else { "N/A" }
        }
    })
    Write-Host " ✓" -ForegroundColor Green
} catch {
    $netInfo = @(@{ Error = $_.Exception.Message })
    Write-Host " ✗" -ForegroundColor Red
}

Write-Host "[6/7] Collecting PowerShell module info..." -NoNewline
try {
    $modules = @(Get-Module -ListAvailable -ErrorAction Stop | Select-Object Name, Version, Path | Sort-Object Name)
    # Limit to first 50 to avoid huge reports
    if (@($modules).Count -gt 50) {
        $moduleInfo = @($modules | Select-Object -First 50)
        $moduleCount = @($modules).Count
        $moduleTruncated = $true
    } else {
        $moduleInfo = @($modules)
        $moduleCount = @($modules).Count
        $moduleTruncated = $false
    }
    Write-Host " ✓" -ForegroundColor Green
} catch {
    $moduleInfo = @()
    $moduleCount = 0
    $moduleTruncated = $false
    Write-Host " ✗" -ForegroundColor Red
}

Write-Host "[7/7] Collecting execution policy info..." -NoNewline
try {
    $execPolicies = Get-ExecutionPolicy -List -ErrorAction Stop
    $execPolicyInfo = @($execPolicies | ForEach-Object {
        @{
            Scope = $_.Scope
            Policy = $_.ExecutionPolicy
        }
    })
    Write-Host " ✓" -ForegroundColor Green
} catch {
    $execPolicyInfo = @(@{ Error = $_.Exception.Message })
    Write-Host " ✗" -ForegroundColor Red
}

# Build HTML report
Write-Host "`nGenerating HTML report..." -NoNewline

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PowerShellGUI System Report - $timestamp</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            margin: 0;
            padding: 20px;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 10px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 {
            margin: 0 0 10px 0;
            font-size: 2.5em;
        }
        .header p {
            margin: 0;
            opacity: 0.9;
        }
        .content {
            padding: 30px;
        }
        .section {
            margin-bottom: 30px;
            border-left: 4px solid #667eea;
            padding-left: 20px;
        }
        .section h2 {
            color: #667eea;
            margin-top: 0;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 10px;
        }
        th, td {
            text-align: left;
            padding: 12px;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #f8f9fa;
            font-weight: 600;
            color: #495057;
        }
        tr:hover {
            background-color: #f1f3f5;
        }
        .info-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 15px;
            margin-top: 10px;
        }
        .info-card {
            background: #f8f9fa;
            border-radius: 5px;
            padding: 15px;
            border-left: 3px solid #667eea;
        }
        .info-card strong {
            display: block;
            color: #495057;
            margin-bottom: 5px;
        }
        .info-card span {
            color: #6c757d;
        }
        .footer {
            text-align: center;
            padding: 20px;
            background: #f8f9fa;
            color: #6c757d;
            font-size: 0.9em;
        }
        .error {
            color: #dc3545;
            font-style: italic;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>PowerShellGUI System Report</h1>
            <p>Generated: $timestamp</p>
            <p>Machine: $($csInfo.Name) | User: $env:USERNAME</p>
        </div>
        
        <div class="content">
            <!-- Operating System Section -->
            <div class="section">
                <h2>Operating System</h2>
                <div class="info-grid">
                    <div class="info-card">
                        <strong>Caption</strong>
                        <span>$($osInfo.Caption)</span>
                    </div>
                    <div class="info-card">
                        <strong>Version</strong>
                        <span>$($osInfo.Version)</span>
                    </div>
                    <div class="info-card">
                        <strong>Architecture</strong>
                        <span>$($osInfo.Architecture)</span>
                    </div>
                    <div class="info-card">
                        <strong>Build Number</strong>
                        <span>$($osInfo.BuildNumber)</span>
                    </div>
                    <div class="info-card">
                        <strong>Install Date</strong>
                        <span>$($osInfo.InstallDate)</span>
                    </div>
                    <div class="info-card">
                        <strong>Last Boot</strong>
                        <span>$($osInfo.LastBootTime)</span>
                    </div>
                </div>
            </div>
            
            <!-- Computer System Section -->
            <div class="section">
                <h2>Computer System</h2>
                <div class="info-grid">
                    <div class="info-card">
                        <strong>Manufacturer</strong>
                        <span>$($csInfo.Manufacturer)</span>
                    </div>
                    <div class="info-card">
                        <strong>Model</strong>
                        <span>$($csInfo.Model)</span>
                    </div>
                    <div class="info-card">
                        <strong>Domain</strong>
                        <span>$($csInfo.Domain)</span>
                    </div>
                    <div class="info-card">
                        <strong>Total Physical Memory</strong>
                        <span>$($csInfo.TotalPhysicalMemory) GB</span>
                    </div>
                    <div class="info-card">
                        <strong>Physical Processors</strong>
                        <span>$($csInfo.NumberOfProcessors)</span>
                    </div>
                    <div class="info-card">
                        <strong>Logical Processors</strong>
                        <span>$($csInfo.NumberOfLogicalProcessors)</span>
                    </div>
                </div>
            </div>
            
            <!-- Processor Section -->
            <div class="section">
                <h2>Processor(s)</h2>
                <table>
                    <tr>
                        <th>Name</th>
                        <th>Cores</th>
                        <th>Logical Processors</th>
                        <th>Max Clock Speed (MHz)</th>
                    </tr>
"@

foreach ($cpu in $cpuInfo) {
    if ($null -ne $cpu.Error) {
        $htmlContent += "<tr><td colspan='4' class='error'>Error: $($cpu.Error)</td></tr>`n"
    } else {
        $htmlContent += "<tr><td>$($cpu.Name)</td><td>$($cpu.Cores)</td><td>$($cpu.LogicalProcessors)</td><td>$($cpu.MaxClockSpeed)</td></tr>`n"
    }
}

$htmlContent += @"
                </table>
            </div>
            
            <!-- Disk Section -->
            <div class="section">
                <h2>Logical Disks</h2>
                <table>
                    <tr>
                        <th>Drive</th>
                        <th>Volume Name</th>
                        <th>File System</th>
                        <th>Size (GB)</th>
                        <th>Free (GB)</th>
                    </tr>
"@

foreach ($disk in $diskInfo) {
    if ($null -ne $disk.Error) {
        $htmlContent += "<tr><td colspan='5' class='error'>Error: $($disk.Error)</td></tr>`n"
    } else {
        $htmlContent += "<tr><td>$($disk.DeviceID)</td><td>$($disk.VolumeName)</td><td>$($disk.FileSystem)</td><td>$($disk.SizeGB)</td><td>$($disk.FreeGB)</td></tr>`n"
    }
}

$htmlContent += @"
                </table>
            </div>
            
            <!-- Network Adapters Section -->
            <div class="section">
                <h2>Network Adapters</h2>
                <table>
                    <tr>
                        <th>Name</th>
                        <th>Status</th>
                        <th>Link Speed</th>
                        <th>MAC Address</th>
                        <th>IPv4 Address</th>
                    </tr>
"@

foreach ($adapter in $netInfo) {
    if ($null -ne $adapter.Error) {
        $htmlContent += "<tr><td colspan='5' class='error'>Error: $($adapter.Error)</td></tr>`n"
    } else {
        $htmlContent += "<tr><td>$($adapter.Name)</td><td>$($adapter.Status)</td><td>$($adapter.LinkSpeed)</td><td>$($adapter.MacAddress)</td><td>$($adapter.IPv4Address)</td></tr>`n"
    }
}

$htmlContent += @"
                </table>
            </div>
            
            <!-- PowerShell Modules Section -->
            <div class="section">
                <h2>PowerShell Modules (Top $(@($moduleInfo).Count) of $moduleCount)</h2>
"@

if ($moduleTruncated) {
    $htmlContent += "<p style='color: #856404; background: #fff3cd; padding: 10px; border-radius: 5px;'><strong>Note:</strong> List truncated to first 50 modules for performance.</p>`n"
}

$htmlContent += @"
                <table>
                    <tr>
                        <th>Name</th>
                        <th>Version</th>
                        <th>Path</th>
                    </tr>
"@

foreach ($module in $moduleInfo) {
    $htmlContent += "<tr><td>$($module.Name)</td><td>$($module.Version)</td><td style='font-size: 0.85em;'>$($module.Path)</td></tr>`n"
}

$htmlContent += @"
                </table>
            </div>
            
            <!-- Execution Policy Section -->
            <div class="section">
                <h2>Execution Policy</h2>
                <table>
                    <tr>
                        <th>Scope</th>
                        <th>Policy</th>
                    </tr>
"@

foreach ($policy in $execPolicyInfo) {
    if ($null -ne $policy.Error) {
        $htmlContent += "<tr><td colspan='2' class='error'>Error: $($policy.Error)</td></tr>`n"
    } else {
        $htmlContent += "<tr><td>$($policy.Scope)</td><td>$($policy.Policy)</td></tr>`n"
    }
}

$htmlContent += @"
                </table>
            </div>
            
            <!-- PowerShell Version Section -->
            <div class="section">
                <h2>PowerShell Version</h2>
                <div class="info-grid">
                    <div class="info-card">
                        <strong>Version</strong>
                        <span>$($PSVersionTable.PSVersion)</span>
                    </div>
                    <div class="info-card">
                        <strong>Edition</strong>
                        <span>$($PSVersionTable.PSEdition)</span>
                    </div>
                    <div class="info-card">
                        <strong>CLR Version</strong>
                        <span>$($PSVersionTable.CLRVersion)</span>
                    </div>
                    <div class="info-card">
                        <strong>Build Version</strong>
                        <span>$($PSVersionTable.BuildVersion)</span>
                    </div>
                </div>
            </div>
        </div>
        
        <div class="footer">
            <p>PowerShellGUI System Report | VersionTag: 2604.B1.v1.0</p>
            <p>Generated by Export-SystemReport.ps1 | The Establishment</p>
        </div>
    </div>
</body>
</html>
"@

# Save report
try {
    $htmlContent | Out-File -FilePath $reportPath -Encoding UTF8 -Force
    Write-Host " ✓" -ForegroundColor Green
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  REPORT GENERATED SUCCESSFULLY                                    ║" -ForegroundColor Green
    Write-Host "║  Path: $reportPath" (" " * (51 - $reportPath.Length)) "║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Green
    
    # Open in browser
    if (-not $SkipBrowserOpen.IsPresent) {
        Write-Host "Opening report in default browser..." -NoNewline
        Start-Process $reportPath
        Write-Host " ✓`n" -ForegroundColor Green
    }
    
    exit 0
} catch {
    Write-Host " ✗" -ForegroundColor Red
    Write-Error "Failed to save report: $_"
    exit 1
}
