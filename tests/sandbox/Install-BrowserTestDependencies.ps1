# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS
    Installs browser test dependencies inside Windows Sandbox.
.DESCRIPTION
    Downloads Selenium WebDriver .NET binaries, browser-specific drivers
    (msedgedriver, chromedriver, geckodriver), and installs missing browsers
    (Firefox via winget with manual fallback). Exports a BrowserManifest
    hashtable for the test orchestrator.
.NOTES
    Author  : The Establishment
    Runs in : Windows Sandbox (WDAGUtilityAccount)
#>
param(
    [Parameter(Mandatory)]
    [string]$WorkspacePath,

    [string]$DriverDir = 'C:\BrowserTestDrivers',

    [string]$OutputPath = 'C:\Users\WDAGUtilityAccount\Desktop\PwShGUI-Output'
)

$ErrorActionPreference = 'Stop'

# ========================== LOGGING ==========================
$logFile = Join-Path $OutputPath 'browser-test-install.log'
function Write-BTLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg"
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'OK'    { 'Green' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    if (Test-Path (Split-Path $logFile -Parent)) {
        Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

# ========================== INIT ==========================
New-Item -ItemType Directory -Path $DriverDir -Force | Out-Null
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# Load config
$configPath = Join-Path $WorkspacePath 'config\browser-test-config.json'
if (-not (Test-Path $configPath)) {
    Write-BTLog "Config not found: $configPath" -Level 'ERROR'
    throw "browser-test-config.json not found"
}
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

Write-BTLog '=================================================================='
Write-BTLog '  Browser Test Dependency Installer'
Write-BTLog '=================================================================='

# ========================== SELENIUM .NET BINARIES ==========================
function Install-SeleniumBindings {
    Write-BTLog 'Installing Selenium .NET bindings...'
    $seleniumDir = Join-Path $DriverDir 'selenium'
    New-Item -ItemType Directory -Path $seleniumDir -Force | Out-Null

    # Use NuGet to download Selenium.WebDriver
    try {
        $nugetPath = Join-Path $DriverDir 'nuget.exe'
        if (-not (Test-Path $nugetPath)) {
            Write-BTLog 'Downloading nuget.exe...'
            Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $nugetPath -UseBasicParsing
        }

        & $nugetPath install Selenium.WebDriver -OutputDirectory $seleniumDir -NonInteractive -Verbosity quiet 2>&1 | Out-Null
        & $nugetPath install Selenium.Support -OutputDirectory $seleniumDir -NonInteractive -Verbosity quiet 2>&1 | Out-Null

        # Find the WebDriver DLL
        $dllPath = Get-ChildItem $seleniumDir -Recurse -Filter 'WebDriver.dll' |
                   Where-Object { $_.FullName -match 'net4|netstandard' } |
                   Select-Object -First 1
        if ($dllPath) {
            Write-BTLog "Selenium DLL: $($dllPath.FullName)" -Level 'OK'
            return $dllPath.FullName
        } else {
            Write-BTLog 'Selenium DLL not found after install' -Level 'ERROR'
            return $null
        }
    } catch {
        Write-BTLog "Selenium install failed: $_" -Level 'ERROR'
        return $null
    }
}

# ========================== BROWSER DETECTION ==========================
function Find-BrowserExe {
    param([string[]]$ExePaths)
    foreach ($p in $ExePaths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-BrowserVersion {
    param([string]$ExePath)
    if (-not $ExePath -or -not (Test-Path $ExePath)) { return $null }
    try {
        $vi = (Get-Item $ExePath).VersionInfo
        return $vi.ProductVersion
    } catch {
        return $null
    }
}

# ========================== EDGE DRIVER ==========================
function Install-EdgeDriver {
    Write-BTLog 'Setting up Edge driver...'
    $edgeCfg = $config.browsers.edge
    $exePath = Find-BrowserExe -ExePaths @($edgeCfg.exePaths)
    if (-not $exePath) {
        Write-BTLog 'Edge not found (should always be present in Sandbox)' -Level 'ERROR'
        return @{ Available = $false; Reason = 'Edge not found' }
    }

    $version = Get-BrowserVersion -ExePath $exePath
    Write-BTLog "Edge version: $version"

    $driverPath = Join-Path $DriverDir $edgeCfg.driverName
    if (-not (Test-Path $driverPath)) {
        try {
            $url = $edgeCfg.driverDownloadUrlTemplate -replace '\{VERSION\}', $version
            $zipPath = Join-Path $DriverDir 'edgedriver.zip'
            Write-BTLog "Downloading Edge driver from: $url"
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
            Expand-Archive -Path $zipPath -DestinationPath $DriverDir -Force
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            # Move driver from subfolder if needed
            $subDriver = Get-ChildItem $DriverDir -Recurse -Filter $edgeCfg.driverName |
                         Where-Object { $_.DirectoryName -ne $DriverDir } |
                         Select-Object -First 1
            if ($subDriver) {
                Move-Item $subDriver.FullName $driverPath -Force
            }
        } catch {
            Write-BTLog "Edge driver download failed: $_" -Level 'ERROR'
            return @{ Available = $false; Reason = "Driver download failed: $_" }
        }
    }

    if (Test-Path $driverPath) {
        Write-BTLog "Edge driver ready: $driverPath" -Level 'OK'
        return @{ Available = $true; DriverPath = $driverPath; ExePath = $exePath; Version = $version }
    }
    return @{ Available = $false; Reason = 'Driver not found after install' }
}

# ========================== CHROME DRIVER ==========================
function Install-ChromeDriver {
    Write-BTLog 'Setting up Chrome driver...'
    $chromeCfg = $config.browsers.chrome
    $exePath = Find-BrowserExe -ExePaths @($chromeCfg.exePaths)
    if (-not $exePath) {
        Write-BTLog 'Chrome not installed -- skipping' -Level 'WARN'
        return @{ Available = $false; Reason = 'Chrome not installed' }
    }

    $version = Get-BrowserVersion -ExePath $exePath
    Write-BTLog "Chrome version: $version"

    $driverPath = Join-Path $DriverDir $chromeCfg.driverName
    if (-not (Test-Path $driverPath)) {
        try {
            # Get matching driver version from Chrome for Testing API
            $cfgUrl = $chromeCfg.driverDownloadUrl
            $cfgJson = Invoke-WebRequest -Uri $cfgUrl -UseBasicParsing | ConvertFrom-Json
            $stableUrl = $null
            if ($cfgJson.channels.Stable.downloads.chromedriver) {
                $stableUrl = ($cfgJson.channels.Stable.downloads.chromedriver |
                              Where-Object { $_.platform -eq 'win64' }).url
            }
            if ($stableUrl) {
                $zipPath = Join-Path $DriverDir 'chromedriver.zip'
                Write-BTLog "Downloading Chrome driver..."
                Invoke-WebRequest -Uri $stableUrl -OutFile $zipPath -UseBasicParsing
                Expand-Archive -Path $zipPath -DestinationPath $DriverDir -Force
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                $subDriver = Get-ChildItem $DriverDir -Recurse -Filter $chromeCfg.driverName |
                             Where-Object { $_.DirectoryName -ne $DriverDir } |
                             Select-Object -First 1
                if ($subDriver) {
                    Move-Item $subDriver.FullName $driverPath -Force
                }
            }
        } catch {
            Write-BTLog "Chrome driver download failed: $_" -Level 'ERROR'
            return @{ Available = $false; Reason = "Driver download failed: $_" }
        }
    }

    if (Test-Path $driverPath) {
        Write-BTLog "Chrome driver ready: $driverPath" -Level 'OK'
        return @{ Available = $true; DriverPath = $driverPath; ExePath = $exePath; Version = $version }
    }
    return @{ Available = $false; Reason = 'Driver not found after install' }
}

# ========================== FIREFOX + GECKODRIVER ==========================
function Install-Firefox {
    Write-BTLog 'Checking Firefox...'
    $ffCfg = $config.browsers.firefox
    $exePath = Find-BrowserExe -ExePaths @($ffCfg.exePaths)

    if (-not $exePath) {
        Write-BTLog 'Firefox not found. Attempting install...' -Level 'WARN'

        # Try winget first
        $wingetAvail = $false
        try {
            $wgTest = & winget --version 2>&1
            if ($LASTEXITCODE -eq 0) { $wingetAvail = $true }
        } catch { } <# Intentional: non-fatal winget availability probe #>

        if ($wingetAvail) {
            Write-BTLog "Installing Firefox via winget ($($ffCfg.wingetId))..."
            try {
                & winget install $ffCfg.wingetId --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
                $exePath = Find-BrowserExe -ExePaths @($ffCfg.exePaths)
            } catch {
                Write-BTLog "Winget install failed: $_" -Level 'WARN'
            }
        }

        if (-not $exePath) {
            # Manual download fallback
            Write-BTLog "Winget unavailable or failed. Downloading Firefox installer..." -Level 'WARN'
            try {
                $installerUrl = 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US'
                $installerPath = Join-Path $DriverDir 'FirefoxSetup.exe'
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
                Write-BTLog "Running Firefox installer silently..."
                $proc = Start-Process $installerPath -ArgumentList '/S' -Wait -PassThru
                if ($proc.ExitCode -eq 0) {
                    $exePath = Find-BrowserExe -ExePaths @($ffCfg.exePaths)
                } else {
                    Write-BTLog "Firefox installer exit code: $($proc.ExitCode)" -Level 'ERROR'
                }
                Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
            } catch {
                Write-BTLog "Firefox manual download failed: $_" -Level 'ERROR'
                Write-BTLog "Manual install URL: $($ffCfg.manualDownloadUrl)" -Level 'WARN'
            }
        }
    }

    if (-not $exePath) {
        Write-BTLog 'Firefox could not be installed' -Level 'ERROR'
        return @{ Available = $false; Reason = 'Firefox install failed' }
    }

    $version = Get-BrowserVersion -ExePath $exePath
    Write-BTLog "Firefox version: $version" -Level 'OK'

    # Install geckodriver
    $driverPath = Join-Path $DriverDir $ffCfg.driverName
    if (-not (Test-Path $driverPath)) {
        try {
            # Get latest geckodriver release
            Write-BTLog 'Downloading geckodriver...'
            $releasesApi = 'https://api.github.com/repos/mozilla/geckodriver/releases/latest'
            $releaseData = Invoke-WebRequest -Uri $releasesApi -UseBasicParsing | ConvertFrom-Json
            $asset = $releaseData.assets | Where-Object { $_.name -match 'win64\.zip$' } | Select-Object -First 1
            if ($asset) {
                $zipPath = Join-Path $DriverDir 'geckodriver.zip'
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
                Expand-Archive -Path $zipPath -DestinationPath $DriverDir -Force
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-BTLog "Geckodriver download failed: $_" -Level 'ERROR'
            return @{ Available = $false; Reason = "Geckodriver download failed: $_"; ExePath = $exePath }
        }
    }

    if (Test-Path $driverPath) {
        Write-BTLog "Geckodriver ready: $driverPath" -Level 'OK'
        return @{ Available = $true; DriverPath = $driverPath; ExePath = $exePath; Version = $version }
    }
    return @{ Available = $false; Reason = 'Geckodriver not found after install'; ExePath = $exePath }
}

# ========================== MAIN ==========================
$seleniumDll = Install-SeleniumBindings

$manifest = @{
    SeleniumDllPath = $seleniumDll
    DriverDir       = $DriverDir
    Edge            = (Install-EdgeDriver)
    Chrome          = (Install-ChromeDriver)
    Firefox         = (Install-Firefox)
    InstalledAt     = (Get-Date -Format 'o')
}

# Persist manifest
$manifestPath = Join-Path $OutputPath 'browser-manifest.json'
ConvertTo-Json $manifest -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-BTLog '=================================================================='
Write-BTLog '  Browser Manifest Summary'
Write-BTLog '=================================================================='
Write-BTLog "  Selenium DLL : $(if ($seleniumDll) { 'OK' } else { 'MISSING' })"
Write-BTLog "  Edge         : $(if ($manifest.Edge.Available) { "OK ($($manifest.Edge.Version))" } else { $manifest.Edge.Reason })"
Write-BTLog "  Chrome       : $(if ($manifest.Chrome.Available) { "OK ($($manifest.Chrome.Version))" } else { $manifest.Chrome.Reason })"
Write-BTLog "  Firefox      : $(if ($manifest.Firefox.Available) { "OK ($($manifest.Firefox.Version))" } else { $manifest.Firefox.Reason })"
Write-BTLog '=================================================================='

# Return manifest for pipeline use
return $manifest

