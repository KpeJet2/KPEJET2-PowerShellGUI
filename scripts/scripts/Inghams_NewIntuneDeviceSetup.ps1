# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# FileRole: Pipeline
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-29 00:00  audit-007 added VersionTag
# PowerShell Script
# Ensure script runs with administrator privileges
If (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Please run this script as Administrator."
    Break
}

# Helper function for logging
Function Log-Message($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "$timestamp - $message"
}

# -----------------------------
# 1. Install/latest .NET Framework
# -----------------------------
Log-Message "Checking for latest .NET Framework version..."

# Define the latest version download URL (can check for latest online manually or automate via API)
$dotNetURL = "https://dotnet.microsoft.com/download/dotnet-framework/net48"  # Change URI to latest if needed
$dotNetInstaller = "$env:TEMP
dp_latest.exe"

# Download .NET installer
Log-Message "Downloading .NET Framework installer..."
Invoke-WebRequest -Uri $dotNetURL -OutFile $dotNetInstaller

# Silent install .NET Framework
Log-Message "Installing .NET Framework..."
Start-Process -FilePath $dotNetInstaller -ArgumentList "/quiet /norestart" -Wait

# -----------------------------
# 2. Install latest PowerShell (PowerShell Core / 7+)
# -----------------------------
Log-Message "Checking for latest PowerShell version..."

# Visit GitHub API for latest PowerShell release
$pwshLatest = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest"

# Construct download URL for Windows x64 MSI
$msiAsset = $pwshLatest.assets | Where-Object { $_.name -match "win-x64.msi" }
$pwshInstaller = "$env:TEMP\$($msiAsset.name)"

# Download installer
Log-Message "Downloading PowerShell $($pwshLatest.tag_name)..."
Invoke-WebRequest -Uri $msiAsset.browser_download_url -OutFile $pwshInstaller

# Silent install PowerShell
Log-Message "Installing PowerShell $($pwshLatest.tag_name)..."
Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$pwshInstaller`" /quiet /norestart" -Wait

# -----------------------------
# 3. Clean up
# -----------------------------
Remove-Item -Path $dotNetInstaller, $pwshInstaller -Force -ErrorAction SilentlyContinue
Log-Message "Update process completed successfully."

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





