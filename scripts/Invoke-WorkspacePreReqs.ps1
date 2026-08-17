# VersionTag: 2608.B1.V54.2
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-08-14
# SupportsPS7.6TestedDate: 2026-08-14
# FileRole: Setup

[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [ValidateSet(
        'CheckAll',
        'SetupAll',
        'Master',
        'CheckRuntimes',
        'SetupRuntimes',
        'CheckPackages',
        'SetupPackages',
        'CheckModules',
        'SetupModules',
        'CheckRepositories',
        'SetupRepositories',
        'CheckFeatures',
        'SetupFeatures',
        'CheckEnvironment',
        'SetupEnvironment'
    )]
    [string]$Action = 'CheckAll'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
    $WorkspacePath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

if (-not (Test-Path -LiteralPath (Join-Path $WorkspacePath 'scripts'))) {
    throw "WorkspacePath is invalid: $WorkspacePath"
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:Timestamp = Get-Date
$script:LogDir = Join-Path (Join-Path $WorkspacePath 'logs') 'prereq'
if (-not (Test-Path -LiteralPath $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan
}

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][ValidateSet('PASS','WARN','FAIL','INFO')][string]$Status,
        [string]$Current = '',
        [string]$Baseline = '',
        [string]$Guidance = ''
    )

    $row = [pscustomobject]@{
        Category = $Category
        Item = $Item
        Status = $Status
        Current = $Current
        Baseline = $Baseline
        Guidance = $Guidance
    }
    $script:Results.Add($row) | Out-Null

    $color = 'Gray'
    switch ($Status) {
        'PASS' { $color = 'Green' }
        'WARN' { $color = 'Yellow' }
        'FAIL' { $color = 'Red' }
        'INFO' { $color = 'Cyan' }
    }

    $line = '{0,-13} {1,-5} {2}' -f $Category, $Status, $Item
    if (-not [string]::IsNullOrWhiteSpace($Current)) {
        $line += " -> $Current"
    }
    Write-Host $line -ForegroundColor $color
}

function Reset-Results {
    $script:Results = New-Object System.Collections.Generic.List[object]
}

function Get-ComparableVersion {
    param([string]$RawVersion)

    if ([string]::IsNullOrWhiteSpace($RawVersion)) { return $null }
    $match = [regex]::Match($RawVersion, '(\d+)(\.\d+){0,3}')
    if (-not $match.Success) { return $null }

    $parts = $match.Value.Split('.')
    while (@($parts).Count -lt 4) { $parts += '0' }
    $normalized = ($parts[0..3] -join '.')
    try { return [version]$normalized } catch { return $null }
}

function Test-VersionAtLeast {
    param(
        [string]$CurrentVersion,
        [string]$MinimumVersion
    )

    $cv = Get-ComparableVersion -RawVersion $CurrentVersion
    $mv = Get-ComparableVersion -RawVersion $MinimumVersion
    if ($null -eq $cv -or $null -eq $mv) { return $false }
    return ($cv -ge $mv)
}

function Get-PrereqBaseline {
    $baselinePath = Join-Path $WorkspacePath 'config\prerequisites-baseline.json'
    if (Test-Path -LiteralPath $baselinePath) {
        try {
            return (Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            Add-Result -Category 'baseline' -Item 'Parse prerequisites-baseline.json' -Status 'WARN' -Current $_.Exception.Message -Guidance 'Using built-in fallback baseline.'
        }
    }

    $fallback = @'
{
  "tools": [
    { "name": "PowerShell 7 x64", "key": "pwsh", "required": true, "minimumVersion": "7.5.0", "recommendedVersion": "7.5.4", "wingetId": "Microsoft.PowerShell", "installIfMissing": true },
    { "name": ".NET SDK x64", "key": "dotnet-sdk", "required": true, "minimumVersion": "8.0.100", "recommendedVersion": "9.0.100", "wingetId": "Microsoft.DotNet.SDK.9", "installIfMissing": true },
    { "name": ".NET WindowsDesktop Runtime x64", "key": "dotnet-desktop-runtime", "required": true, "minimumVersion": "8.0.0", "recommendedVersion": "9.0.0", "wingetId": "Microsoft.DotNet.DesktopRuntime.9", "installIfMissing": true },
    { "name": "Python", "key": "python", "required": true, "minimumVersion": "3.11.0", "recommendedVersion": "3.12.0", "wingetId": "Python.Python.3.12", "installIfMissing": true },
    { "name": "Windows Terminal", "key": "windows-terminal", "required": true, "minimumVersion": "1.20.0", "recommendedVersion": "1.21.0", "wingetId": "Microsoft.WindowsTerminal", "installIfMissing": true }
  ],
  "repositories": {
    "psRepository": { "requiredNames": ["PSGallery"], "minimumTrustedCount": 1 },
    "psResourceRepository": { "requiredNames": ["PSGallery"], "minimumTrustedCount": 1 }
  },
  "modules": [
    { "name": "PowerShellGet", "required": true, "minimumVersion": "2.2.5" },
    { "name": "PackageManagement", "required": true, "minimumVersion": "1.4.8.1" },
    { "name": "Microsoft.PowerShell.PSResourceGet", "required": true, "minimumVersion": "1.0.0" }
  ],
  "environmentVariables": [
    { "name": "Path", "required": true },
    { "name": "PSModulePath", "required": true },
    { "name": "TEMP", "required": true },
    { "name": "ProgramFiles", "required": true }
  ]
}
'@
    return ($fallback | ConvertFrom-Json)
}

function Get-ToolVersionByKey {
    param([Parameter(Mandatory)][string]$ToolKey)

    switch ($ToolKey.ToLowerInvariant()) {
        'pwsh' {
            $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($null -eq $cmd) { return '' }
            try {
                return ((& $cmd.Source -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1 | Out-String).Trim())
            } catch {
                return ''
            }
        }
        'dotnet-sdk' {
            $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
            if ($null -eq $cmd) { return '' }
            try { return ((& $cmd.Source --version 2>&1 | Out-String).Trim()) } catch { return '' }
        }
        'dotnet-desktop-runtime' {
            $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
            if ($null -eq $cmd) { return '' }
            try {
                $lines = @(& $cmd.Source --list-runtimes 2>&1)
                $versions = @($lines | ForEach-Object {
                    $m = [regex]::Match([string]$_, '^Microsoft\.WindowsDesktop\.App\s+([0-9]+\.[0-9]+\.[0-9]+)')
                    if ($m.Success) { $m.Groups[1].Value }
                } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if (@($versions).Count -eq 0) { return '' }
                return [string](($versions | Sort-Object { Get-ComparableVersion $_ } -Descending | Select-Object -First 1))
            } catch {
                return ''
            }
        }
        'python' {
            $cmd = Get-Command python -ErrorAction SilentlyContinue
            if ($null -ne $cmd) {
                try { return ((& $cmd.Source --version 2>&1 | Out-String).Trim()) } catch { }
            }
            $py = Get-Command py -ErrorAction SilentlyContinue
            if ($null -ne $py) {
                try { return ((& $py.Source -V 2>&1 | Out-String).Trim()) } catch { }
            }
            return ''
        }
        'windows-terminal' {
            $cmd = Get-Command wt -ErrorAction SilentlyContinue
            if ($null -eq $cmd) { return '' }
            try { return ((& $cmd.Source -v 2>&1 | Out-String).Trim()) } catch { return '' }
        }
        'winget' {
            $cmd = Get-Command winget -ErrorAction SilentlyContinue
            if ($null -eq $cmd) { return '' }
            try { return ((& $cmd.Source --version 2>&1 | Out-String).Trim()) } catch { return '' }
        }
        default {
            $cmd = Get-Command $ToolKey -ErrorAction SilentlyContinue
            if ($null -eq $cmd) { return '' }
            try { return [string](Get-Item -LiteralPath $cmd.Source).VersionInfo.ProductVersion } catch { return '' }
        }
    }
}

function Get-HighestModuleVersion {
    param([Parameter(Mandatory)][string]$ModuleName)

    try {
        $module = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
        if ($null -ne $module) { return [string]$module.Version }
    } catch {
        return ''
    }
    return ''
}

function Get-WindowsFeatureState {
    param([Parameter(Mandatory)][string]$FeatureName)

    $cmd = Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return 'Unavailable'
    }

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
        return [string]$feature.State
    } catch {
        return 'Unknown'
    }
}

function Invoke-CheckRuntimes {
    Write-Section 'Check: Windows runtimes and shells'

    $baseline = Get-PrereqBaseline
    $runtimeKeys = @('pwsh','dotnet-sdk','dotnet-desktop-runtime','python','windows-terminal')
    foreach ($tool in @($baseline.tools | Where-Object { $runtimeKeys -contains [string]$_.key })) {
        $name = [string]$tool.name
        $key = [string]$tool.key
        $minimumVersion = [string]$tool.minimumVersion
        $current = Get-ToolVersionByKey -ToolKey $key
        $required = [bool]$tool.required

        if ([string]::IsNullOrWhiteSpace($current)) {
            $status = if ($required) { 'FAIL' } else { 'WARN' }
            $guidance = if ($tool.wingetId) { "winget install --id $($tool.wingetId)" } else { 'Install tool and add it to PATH.' }
            Add-Result -Category 'runtime' -Item $name -Status $status -Current 'Not detected' -Baseline "min $minimumVersion" -Guidance $guidance
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($minimumVersion) -and -not (Test-VersionAtLeast -CurrentVersion $current -MinimumVersion $minimumVersion)) {
            $guidance = if ($tool.wingetId) { "winget upgrade --id $($tool.wingetId)" } else { 'Upgrade tool.' }
            Add-Result -Category 'runtime' -Item $name -Status 'WARN' -Current $current -Baseline "min $minimumVersion" -Guidance $guidance
            continue
        }

        Add-Result -Category 'runtime' -Item $name -Status 'PASS' -Current $current -Baseline "min $minimumVersion"
    }

    $ps51Path = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps51Path) {
        Add-Result -Category 'runtime' -Item 'Windows PowerShell 5.1 host' -Status 'PASS' -Current $ps51Path
    } else {
        Add-Result -Category 'runtime' -Item 'Windows PowerShell 5.1 host' -Status 'FAIL' -Current 'Not found' -Guidance 'Repair Windows PowerShell feature on this host.'
    }

    $webView2Installed = $false
    try {
        $wv2 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEB-E15AB5B8BB31}' -ErrorAction SilentlyContinue
        if ($null -eq $wv2) {
            $wv2 = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEB-E15AB5B8BB31}' -ErrorAction SilentlyContinue
        }
        if ($null -ne $wv2) { $webView2Installed = $true }
    } catch {
        $webView2Installed = $false
    }

    if ($webView2Installed) {
        Add-Result -Category 'runtime' -Item 'Microsoft Edge WebView2 Runtime' -Status 'PASS' -Current 'Detected'
    } else {
        Add-Result -Category 'runtime' -Item 'Microsoft Edge WebView2 Runtime' -Status 'WARN' -Current 'Not detected' -Guidance 'winget install --id Microsoft.EdgeWebView2Runtime'
    }
}

function Invoke-CheckPackages {
    Write-Section 'Check: package managers and CLI packages'

    $checks = @(
        @{ Name = 'winget'; Required = $true; Version = (Get-ToolVersionByKey -ToolKey 'winget'); Guidance = 'Install App Installer from Microsoft Store if missing.' },
        @{ Name = 'git'; Required = $true; Version = $(if (Get-Command git -ErrorAction SilentlyContinue) { ((& git --version 2>&1 | Out-String).Trim()) } else { '' }); Guidance = 'winget install --id Git.Git' },
        @{ Name = 'node'; Required = $false; Version = $(if (Get-Command node -ErrorAction SilentlyContinue) { ((& node --version 2>&1 | Out-String).Trim()) } else { '' }); Guidance = 'winget install --id OpenJS.NodeJS.LTS' },
        @{ Name = 'npm'; Required = $false; Version = $(if (Get-Command npm -ErrorAction SilentlyContinue) { ((& npm --version 2>&1 | Out-String).Trim()) } else { '' }); Guidance = 'Install Node.js LTS to get npm.' },
        @{ Name = 'python'; Required = $true; Version = (Get-ToolVersionByKey -ToolKey 'python'); Guidance = 'winget install --id Python.Python.3.12' },
        @{ Name = 'pip'; Required = $true; Version = $(if (Get-Command python -ErrorAction SilentlyContinue) { ((& python -m pip --version 2>&1 | Out-String).Trim()) } else { '' }); Guidance = 'python -m ensurepip --upgrade' },
        @{ Name = 'bw (Bitwarden CLI)'; Required = $false; Version = $(if (Get-Command bw -ErrorAction SilentlyContinue) { ((& bw --version 2>&1 | Out-String).Trim()) } else { '' }); Guidance = 'winget install --id Bitwarden.CLI' }
    )

    foreach ($check in $checks) {
        $ver = [string]$check.Version
        if ([string]::IsNullOrWhiteSpace($ver)) {
            Add-Result -Category 'package' -Item ([string]$check.Name) -Status $(if ($check.Required) { 'FAIL' } else { 'WARN' }) -Current 'Not detected' -Guidance ([string]$check.Guidance)
        } else {
            Add-Result -Category 'package' -Item ([string]$check.Name) -Status 'PASS' -Current $ver
        }
    }
}

function Invoke-CheckModules {
    Write-Section 'Check: PowerShell modules and workspace modules'

    $baseline = Get-PrereqBaseline
    foreach ($module in @($baseline.modules)) {
        $moduleName = [string]$module.name
        $minimumVersion = [string]$module.minimumVersion
        $currentVersion = Get-HighestModuleVersion -ModuleName $moduleName

        if ([string]::IsNullOrWhiteSpace($currentVersion)) {
            Add-Result -Category 'module' -Item $moduleName -Status $(if ($module.required) { 'FAIL' } else { 'WARN' }) -Current 'Not installed' -Baseline "min $minimumVersion" -Guidance "Install-Module -Name $moduleName -Scope CurrentUser"
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($minimumVersion) -and -not (Test-VersionAtLeast -CurrentVersion $currentVersion -MinimumVersion $minimumVersion)) {
            Add-Result -Category 'module' -Item $moduleName -Status 'WARN' -Current $currentVersion -Baseline "min $minimumVersion" -Guidance "Install-Module -Name $moduleName -Scope CurrentUser -Force"
            continue
        }

        Add-Result -Category 'module' -Item $moduleName -Status 'PASS' -Current $currentVersion -Baseline "min $minimumVersion"
    }

    $pesterVersion = Get-HighestModuleVersion -ModuleName 'Pester'
    if ([string]::IsNullOrWhiteSpace($pesterVersion)) {
        Add-Result -Category 'module' -Item 'Pester' -Status 'FAIL' -Current 'Not installed' -Baseline 'min 5.0.0' -Guidance 'Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser -Force'
    } elseif (-not (Test-VersionAtLeast -CurrentVersion $pesterVersion -MinimumVersion '5.0.0')) {
        Add-Result -Category 'module' -Item 'Pester' -Status 'WARN' -Current $pesterVersion -Baseline 'min 5.0.0' -Guidance 'Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser -Force'
    } else {
        Add-Result -Category 'module' -Item 'Pester' -Status 'PASS' -Current $pesterVersion -Baseline 'min 5.0.0'
    }

    $workspaceModuleFiles = @(
        'PwShGUICore.psm1',
        'PwShGUI-Theme.psm1',
        'CronAiAthon-EventLog.psm1',
        'CronAiAthon-Pipeline.psm1',
        'CronAiAthon-Scheduler.psm1'
    )

    foreach ($moduleFile in $workspaceModuleFiles) {
        $modulePath = Join-Path (Join-Path $WorkspacePath 'modules') $moduleFile
        if (Test-Path -LiteralPath $modulePath) {
            Add-Result -Category 'module' -Item "workspace/$moduleFile" -Status 'PASS' -Current 'Present'
        } else {
            Add-Result -Category 'module' -Item "workspace/$moduleFile" -Status 'FAIL' -Current 'Missing' -Guidance 'Restore missing module file in workspace/modules.'
        }
    }
}

function Invoke-CheckRepositories {
    Write-Section 'Check: galleries and repositories'

    $baseline = Get-PrereqBaseline

    if (Get-Command Get-PSRepository -ErrorAction SilentlyContinue) {
        $repos = @(Get-PSRepository -ErrorAction SilentlyContinue)
        $requiredNames = @($baseline.repositories.psRepository.requiredNames)
        foreach ($name in $requiredNames) {
            $repo = $repos | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($null -ne $repo) {
                Add-Result -Category 'repo' -Item "PSRepository/$name" -Status 'PASS' -Current "Trusted=$($repo.InstallationPolicy -eq 'Trusted')"
            } else {
                Add-Result -Category 'repo' -Item "PSRepository/$name" -Status 'FAIL' -Current 'Missing' -Guidance 'Register-PSRepository -Default'
            }
        }

        $trustedCount = @($repos | Where-Object { $_.InstallationPolicy -eq 'Trusted' }).Count
        $minimumTrusted = [int]$baseline.repositories.psRepository.minimumTrustedCount
        if ($trustedCount -ge $minimumTrusted) {
            Add-Result -Category 'repo' -Item 'PSRepository trusted count' -Status 'PASS' -Current $trustedCount -Baseline ">= $minimumTrusted"
        } else {
            Add-Result -Category 'repo' -Item 'PSRepository trusted count' -Status 'WARN' -Current $trustedCount -Baseline ">= $minimumTrusted" -Guidance 'Set-PSRepository -Name PSGallery -InstallationPolicy Trusted'
        }
    } else {
        Add-Result -Category 'repo' -Item 'Get-PSRepository cmdlet' -Status 'WARN' -Current 'Unavailable' -Guidance 'Install/repair PowerShellGet and PackageManagement.'
    }

    if (Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue) {
        $resourceRepos = @(Get-PSResourceRepository -ErrorAction SilentlyContinue)
        $requiredNames = @($baseline.repositories.psResourceRepository.requiredNames)
        foreach ($name in $requiredNames) {
            $repo = $resourceRepos | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($null -ne $repo) {
                Add-Result -Category 'repo' -Item "PSResourceRepository/$name" -Status 'PASS' -Current "Trusted=$($repo.Trusted)"
            } else {
                Add-Result -Category 'repo' -Item "PSResourceRepository/$name" -Status 'WARN' -Current 'Missing' -Guidance "Set-PSResourceRepository -Name '$name' -Trusted"
            }
        }
    } else {
        Add-Result -Category 'repo' -Item 'Get-PSResourceRepository cmdlet' -Status 'WARN' -Current 'Unavailable' -Guidance 'Install Microsoft.PowerShell.PSResourceGet module.'
    }

    $galleryPath = Join-Path $WorkspacePath 'gallery'
    if (Test-Path -LiteralPath $galleryPath) {
        Add-Result -Category 'repo' -Item 'workspace/gallery folder' -Status 'PASS' -Current $galleryPath
    } else {
        Add-Result -Category 'repo' -Item 'workspace/gallery folder' -Status 'WARN' -Current 'Missing' -Guidance 'Create workspace gallery folder or run setup action.'
    }

    $workspaceRepo = if (Get-Command Get-PSRepository -ErrorAction SilentlyContinue) { Get-PSRepository -Name WorkspaceRepo -ErrorAction SilentlyContinue } else { $null }
    if ($null -ne $workspaceRepo) {
        Add-Result -Category 'repo' -Item 'PSRepository/WorkspaceRepo' -Status 'PASS' -Current $workspaceRepo.SourceLocation
    } else {
        Add-Result -Category 'repo' -Item 'PSRepository/WorkspaceRepo' -Status 'WARN' -Current 'Not registered' -Guidance 'Run scripts/Register-WorkspaceRepository.ps1'
    }
}

function Invoke-CheckFeatures {
    Write-Section 'Check: Windows features used by workspace'

    $sandboxExe = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
    if (Test-Path -LiteralPath $sandboxExe) {
        Add-Result -Category 'feature' -Item 'WindowsSandbox.exe' -Status 'PASS' -Current $sandboxExe
    } else {
        Add-Result -Category 'feature' -Item 'WindowsSandbox.exe' -Status 'FAIL' -Current 'Not found' -Guidance 'Enable Windows Sandbox feature.'
    }

    $featureChecks = @(
        @{ Name = 'Windows Sandbox'; Feature = 'Containers-DisposableClientVM'; Required = $true },
        @{ Name = 'Hyper-V'; Feature = 'Microsoft-Hyper-V-All'; Required = $false },
        @{ Name = 'Virtual Machine Platform'; Feature = 'VirtualMachinePlatform'; Required = $false }
    )

    foreach ($fc in $featureChecks) {
        $state = Get-WindowsFeatureState -FeatureName ([string]$fc.Feature)
        if ($state -eq 'Enabled') {
            Add-Result -Category 'feature' -Item ([string]$fc.Name) -Status 'PASS' -Current $state
        } elseif ($state -eq 'Unavailable') {
            Add-Result -Category 'feature' -Item ([string]$fc.Name) -Status 'WARN' -Current $state -Guidance 'Get-WindowsOptionalFeature cmdlet is unavailable in this host session.'
        } else {
            Add-Result -Category 'feature' -Item ([string]$fc.Name) -Status $(if ($fc.Required) { 'FAIL' } else { 'WARN' }) -Current $state -Guidance "Enable-WindowsOptionalFeature -Online -FeatureName $($fc.Feature) -All -NoRestart"
        }
    }

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $virt = [bool]$cpu.VirtualizationFirmwareEnabled
        if ($virt) {
            Add-Result -Category 'feature' -Item 'CPU virtualization firmware' -Status 'PASS' -Current 'Enabled'
        } else {
            Add-Result -Category 'feature' -Item 'CPU virtualization firmware' -Status 'WARN' -Current 'Disabled' -Guidance 'Enable virtualization in BIOS/UEFI to use Sandbox reliably.'
        }
    } catch {
        Add-Result -Category 'feature' -Item 'CPU virtualization firmware' -Status 'WARN' -Current 'Unknown' -Guidance 'Unable to query Win32_Processor virtualization state.'
    }
}

function Invoke-CheckEnvironment {
    Write-Section 'Check: environment variables and workspace path setup'

    $baseline = Get-PrereqBaseline
    foreach ($envSpec in @($baseline.environmentVariables)) {
        $envName = [string]$envSpec.name
        $val = [Environment]::GetEnvironmentVariable($envName, 'Process')
        if ([string]::IsNullOrWhiteSpace($val)) {
            $val = [Environment]::GetEnvironmentVariable($envName, 'User')
        }
        if ([string]::IsNullOrWhiteSpace($val)) {
            $val = [Environment]::GetEnvironmentVariable($envName, 'Machine')
        }

        if ([string]::IsNullOrWhiteSpace($val)) {
            Add-Result -Category 'env' -Item $envName -Status $(if ($envSpec.required) { 'FAIL' } else { 'WARN' }) -Current 'Missing or empty'
        } else {
            Add-Result -Category 'env' -Item $envName -Status 'PASS' -Current 'Set'
        }
    }

    $workspaceModules = Join-Path $WorkspacePath 'modules'
    if ($env:PSModulePath -like "*$workspaceModules*") {
        Add-Result -Category 'env' -Item 'PSModulePath includes workspace/modules' -Status 'PASS' -Current 'Yes'
    } else {
        Add-Result -Category 'env' -Item 'PSModulePath includes workspace/modules' -Status 'WARN' -Current 'No' -Guidance 'Run scripts/Set-WorkspaceModulePath.ps1'
    }
}

function Invoke-WingetEnsurePackage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Id
    )

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Add-Result -Category 'setup' -Item "winget/$Name" -Status 'FAIL' -Current 'winget not available' -Guidance 'Install App Installer from Microsoft Store.'
        return
    }

    try {
        $upgradeOut = (& winget upgrade --id $Id --source winget --accept-source-agreements --accept-package-agreements 2>&1 | Out-String)
        if ($upgradeOut -match 'No applicable update found') {
            Add-Result -Category 'setup' -Item "winget/$Name" -Status 'PASS' -Current 'Already up to date'
            return
        }

        if ($upgradeOut -match 'No installed package found' -or $upgradeOut -match 'No package found matching input criteria') {
            $installOut = (& winget install --id $Id --source winget --accept-source-agreements --accept-package-agreements 2>&1 | Out-String)
            if ($installOut -match 'Successfully installed' -or $installOut -match 'No applicable update found') {
                Add-Result -Category 'setup' -Item "winget/$Name" -Status 'PASS' -Current 'Installed'
            } else {
                Add-Result -Category 'setup' -Item "winget/$Name" -Status 'WARN' -Current ($installOut.Trim())
            }
            return
        }

        if ($upgradeOut -match 'Successfully installed' -or $upgradeOut -match 'Successfully upgraded') {
            Add-Result -Category 'setup' -Item "winget/$Name" -Status 'PASS' -Current 'Upgraded'
        } else {
            Add-Result -Category 'setup' -Item "winget/$Name" -Status 'WARN' -Current ($upgradeOut.Trim())
        }
    } catch {
        Add-Result -Category 'setup' -Item "winget/$Name" -Status 'FAIL' -Current $_.Exception.Message
    }
}

function Invoke-SetupRuntimes {
    Write-Section 'Setup: runtimes and shells'

    $baseline = Get-PrereqBaseline
    foreach ($tool in @($baseline.tools | Where-Object { $_.required -and -not [string]::IsNullOrWhiteSpace($_.wingetId) })) {
        Invoke-WingetEnsurePackage -Name ([string]$tool.name) -Id ([string]$tool.wingetId)
    }

    Invoke-WingetEnsurePackage -Name 'Microsoft Edge WebView2 Runtime' -Id 'Microsoft.EdgeWebView2Runtime'
}

function Invoke-SetupPackages {
    Write-Section 'Setup: package managers and packages'

    Invoke-WingetEnsurePackage -Name 'Git' -Id 'Git.Git'
    Invoke-WingetEnsurePackage -Name 'Node.js LTS' -Id 'OpenJS.NodeJS.LTS'
    Invoke-WingetEnsurePackage -Name 'Bitwarden CLI' -Id 'Bitwarden.CLI'

    if (Get-Command python -ErrorAction SilentlyContinue) {
        try {
            $pipOut = (& python -m pip install --upgrade pip 2>&1 | Out-String).Trim()
            Add-Result -Category 'setup' -Item 'pip self-upgrade' -Status 'PASS' -Current $pipOut
        } catch {
            Add-Result -Category 'setup' -Item 'pip self-upgrade' -Status 'WARN' -Current $_.Exception.Message
        }
    } else {
        Add-Result -Category 'setup' -Item 'pip self-upgrade' -Status 'WARN' -Current 'python command not available'
    }

    if (Get-Command npm -ErrorAction SilentlyContinue) {
        try {
            $npmOut = (& npm install -g npm 2>&1 | Out-String).Trim()
            Add-Result -Category 'setup' -Item 'npm self-upgrade' -Status 'PASS' -Current $npmOut
        } catch {
            Add-Result -Category 'setup' -Item 'npm self-upgrade' -Status 'WARN' -Current $_.Exception.Message -Guidance 'Run elevated if global npm package install is blocked.'
        }
    } else {
        Add-Result -Category 'setup' -Item 'npm self-upgrade' -Status 'INFO' -Current 'npm not available; skip'
    }
}

function Invoke-SetupModules {
    Write-Section 'Setup: PowerShell modules'

    try {
        if (Get-Command Install-PackageProvider -ErrorAction SilentlyContinue) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            Add-Result -Category 'setup' -Item 'NuGet package provider' -Status 'PASS' -Current 'Installed/updated'
        } else {
            Add-Result -Category 'setup' -Item 'NuGet package provider' -Status 'WARN' -Current 'Install-PackageProvider cmdlet unavailable'
        }
    } catch {
        Add-Result -Category 'setup' -Item 'NuGet package provider' -Status 'WARN' -Current $_.Exception.Message
    }

    try {
        if (Get-Command Register-PSRepository -ErrorAction SilentlyContinue) {
            $psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
            if ($null -eq $psGallery) {
                Register-PSRepository -Default -ErrorAction Stop
            }
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Add-Result -Category 'setup' -Item 'PSGallery repository trust' -Status 'PASS' -Current 'Trusted'
        } else {
            Add-Result -Category 'setup' -Item 'PSGallery repository trust' -Status 'WARN' -Current 'PowerShellGet repository cmdlets unavailable'
        }
    } catch {
        Add-Result -Category 'setup' -Item 'PSGallery repository trust' -Status 'WARN' -Current $_.Exception.Message
    }

    $baseline = Get-PrereqBaseline
    $moduleList = @($baseline.modules)
    $moduleList += [pscustomobject]@{ name = 'Pester'; minimumVersion = '5.0.0'; required = $true }

    foreach ($module in $moduleList) {
        $name = [string]$module.name
        $minimumVersion = [string]$module.minimumVersion
        $currentVersion = Get-HighestModuleVersion -ModuleName $name
        $needsInstall = $false

        if ([string]::IsNullOrWhiteSpace($currentVersion)) {
            $needsInstall = $true
        } elseif (-not [string]::IsNullOrWhiteSpace($minimumVersion) -and -not (Test-VersionAtLeast -CurrentVersion $currentVersion -MinimumVersion $minimumVersion)) {
            $needsInstall = $true
        }

        if (-not $needsInstall) {
            Add-Result -Category 'setup' -Item "module/$name" -Status 'PASS' -Current "Already installed ($currentVersion)"
            continue
        }

        try {
            if ([string]::IsNullOrWhiteSpace($minimumVersion)) {
                Install-Module -Name $name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            } else {
                Install-Module -Name $name -MinimumVersion $minimumVersion -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            }
            $newVersion = Get-HighestModuleVersion -ModuleName $name
            Add-Result -Category 'setup' -Item "module/$name" -Status 'PASS' -Current "Installed/updated ($newVersion)"
        } catch {
            Add-Result -Category 'setup' -Item "module/$name" -Status 'FAIL' -Current $_.Exception.Message
        }
    }
}

function Invoke-SetupRepositories {
    Write-Section 'Setup: galleries and repositories'

    $galleryPath = Join-Path $WorkspacePath 'gallery'
    if (-not (Test-Path -LiteralPath $galleryPath)) {
        New-Item -ItemType Directory -Path $galleryPath -Force | Out-Null
        Add-Result -Category 'setup' -Item 'workspace/gallery folder' -Status 'PASS' -Current "Created: $galleryPath"
    } else {
        Add-Result -Category 'setup' -Item 'workspace/gallery folder' -Status 'PASS' -Current "Present: $galleryPath"
    }

    $repoScript = Join-Path $WorkspacePath 'scripts\Register-WorkspaceRepository.ps1'
    if (Test-Path -LiteralPath $repoScript) {
        try {
            & $repoScript
            Add-Result -Category 'setup' -Item 'Register-WorkspaceRepository.ps1' -Status 'PASS' -Current 'Executed'
        } catch {
            Add-Result -Category 'setup' -Item 'Register-WorkspaceRepository.ps1' -Status 'WARN' -Current $_.Exception.Message
        }
    } else {
        Add-Result -Category 'setup' -Item 'Register-WorkspaceRepository.ps1' -Status 'WARN' -Current 'Missing script'
    }

    try {
        if (Get-Command Set-PSRepository -ErrorAction SilentlyContinue) {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Add-Result -Category 'setup' -Item 'PSGallery trusted policy' -Status 'PASS' -Current 'Trusted'
        }
    } catch {
        Add-Result -Category 'setup' -Item 'PSGallery trusted policy' -Status 'WARN' -Current $_.Exception.Message
    }

    try {
        if (Get-Command Set-PSResourceRepository -ErrorAction SilentlyContinue -and Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue) {
            $psRes = Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue
            if ($null -ne $psRes) {
                Set-PSResourceRepository -Name PSGallery -Trusted -ErrorAction SilentlyContinue
                Add-Result -Category 'setup' -Item 'PSResource PSGallery trust' -Status 'PASS' -Current 'Trusted'
            } else {
                Add-Result -Category 'setup' -Item 'PSResource PSGallery trust' -Status 'WARN' -Current 'PSGallery resource repository not found'
            }
        }
    } catch {
        Add-Result -Category 'setup' -Item 'PSResource PSGallery trust' -Status 'WARN' -Current $_.Exception.Message
    }
}

function Invoke-SetupFeatures {
    Write-Section 'Setup: Windows features'

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    $featureChecks = @(
        @{ Name = 'Windows Sandbox'; Feature = 'Containers-DisposableClientVM'; Required = $true },
        @{ Name = 'Hyper-V'; Feature = 'Microsoft-Hyper-V-All'; Required = $false },
        @{ Name = 'Virtual Machine Platform'; Feature = 'VirtualMachinePlatform'; Required = $false }
    )

    if (-not $isAdmin) {
        foreach ($fc in $featureChecks) {
            Add-Result -Category 'setup' -Item "feature/$($fc.Name)" -Status 'WARN' -Current 'Skipped (administrator required)' -Guidance "Run elevated: Enable-WindowsOptionalFeature -Online -FeatureName $($fc.Feature) -All -NoRestart"
        }
        return
    }

    if (-not (Get-Command Enable-WindowsOptionalFeature -ErrorAction SilentlyContinue)) {
        Add-Result -Category 'setup' -Item 'Enable-WindowsOptionalFeature cmdlet' -Status 'FAIL' -Current 'Unavailable'
        return
    }

    foreach ($fc in $featureChecks) {
        $state = Get-WindowsFeatureState -FeatureName ([string]$fc.Feature)
        if ($state -eq 'Enabled') {
            Add-Result -Category 'setup' -Item "feature/$($fc.Name)" -Status 'PASS' -Current 'Already enabled'
            continue
        }

        try {
            Enable-WindowsOptionalFeature -Online -FeatureName ([string]$fc.Feature) -All -NoRestart -ErrorAction Stop | Out-Null
            Add-Result -Category 'setup' -Item "feature/$($fc.Name)" -Status 'PASS' -Current 'Enable command completed (restart may be required)'
        } catch {
            Add-Result -Category 'setup' -Item "feature/$($fc.Name)" -Status 'WARN' -Current $_.Exception.Message
        }
    }
}

function Invoke-SetupEnvironment {
    Write-Section 'Setup: workspace environment wiring'

    $setPathScript = Join-Path $WorkspacePath 'scripts\Set-WorkspaceModulePath.ps1'
    if (Test-Path -LiteralPath $setPathScript) {
        try {
            & $setPathScript
            Add-Result -Category 'setup' -Item 'Set-WorkspaceModulePath.ps1' -Status 'PASS' -Current 'Executed'
        } catch {
            Add-Result -Category 'setup' -Item 'Set-WorkspaceModulePath.ps1' -Status 'WARN' -Current $_.Exception.Message
        }
    } else {
        Add-Result -Category 'setup' -Item 'Set-WorkspaceModulePath.ps1' -Status 'WARN' -Current 'Missing script'
    }
}

function Invoke-AllChecks {
    Invoke-CheckRuntimes
    Invoke-CheckPackages
    Invoke-CheckModules
    Invoke-CheckRepositories
    Invoke-CheckFeatures
    Invoke-CheckEnvironment
}

function Invoke-AllSetup {
    Invoke-SetupRuntimes
    Invoke-SetupPackages
    Invoke-SetupModules
    Invoke-SetupRepositories
    Invoke-SetupFeatures
    Invoke-SetupEnvironment
}

function Write-Report {
    param([Parameter(Mandatory)][string]$ReportAction)
    try {
        $passCount = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
        $warnCount = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
        $failCount = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
        $infoCount = @($script:Results | Where-Object { $_.Status -eq 'INFO' }).Count

        $resultRows = @($script:Results.ToArray())

        $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
        $reportCsvPath = Join-Path $script:LogDir ("prereq-report-$stamp-$ReportAction.csv")
        $reportSummaryPath = Join-Path $script:LogDir ("prereq-report-$stamp-$ReportAction.txt")

        $resultRows | Export-Csv -LiteralPath $reportCsvPath -NoTypeInformation -Encoding UTF8

        $summaryLines = @(
            'PwShGUI prerequisite report',
            "Timestamp: $((Get-Date).ToString('o'))",
            "Workspace: $WorkspacePath",
            "Action: $ReportAction",
            "Host: $env:COMPUTERNAME",
            "User: $env:USERNAME",
            "PASS=$passCount WARN=$warnCount FAIL=$failCount INFO=$infoCount TOTAL=$(@($resultRows).Count)",
            "CSV: $reportCsvPath"
        )
        Set-Content -LiteralPath $reportSummaryPath -Value $summaryLines -Encoding UTF8

        Write-Host ''
        Write-Host "Report written: $reportSummaryPath" -ForegroundColor Cyan
        Write-Host "Details CSV : $reportCsvPath" -ForegroundColor Cyan
        Write-Host ("Summary: PASS={0} WARN={1} FAIL={2} INFO={3}" -f $passCount, $warnCount, $failCount, $infoCount) -ForegroundColor Cyan

        return [pscustomobject]@{
            Path = $reportSummaryPath
            CsvPath = $reportCsvPath
            Pass = $passCount
            Warn = $warnCount
            Fail = $failCount
            Info = $infoCount
            Total = @($resultRows).Count
        }
    } catch {
        Write-Host "[FAIL] Write-Report failed: $($_.Exception.GetType().FullName) :: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[FAIL] Stack: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
        throw
    }
}

function Invoke-MasterFlow {
    Write-Section 'MASTER FLOW: Check + report + setup/upgrade + recheck'

    Reset-Results
    Invoke-AllChecks
    $before = Write-Report -ReportAction 'master-before'

    Invoke-AllSetup

    Reset-Results
    Invoke-AllChecks
    $after = Write-Report -ReportAction 'master-after'

    $masterPath = Join-Path $script:LogDir 'prereq-master-latest.json'
    $master = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        workspace = $WorkspacePath
        action = 'Master'
        before = [ordered]@{
            summaryPath = [string]$before.Path
            csvPath = [string]$before.CsvPath
            pass = [int]$before.Pass
            warn = [int]$before.Warn
            fail = [int]$before.Fail
            info = [int]$before.Info
            total = [int]$before.Total
        }
        after = [ordered]@{
            summaryPath = [string]$after.Path
            csvPath = [string]$after.CsvPath
            pass = [int]$after.Pass
            warn = [int]$after.Warn
            fail = [int]$after.Fail
            info = [int]$after.Info
            total = [int]$after.Total
        }
        status = if ($after.Fail -gt 0) { 'FAIL' } else { 'PASS' }
    }
    $master | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $masterPath -Encoding UTF8
    Write-Host ('Master report written: ' + $masterPath) -ForegroundColor Cyan

    if ($after.Fail -gt 0) { return 1 }
    return 0
}

$exitCode = 0
switch ($Action) {
    'CheckAll' {
        Reset-Results
        Invoke-AllChecks
        $summary = Write-Report -ReportAction 'check-all'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'SetupAll' {
        Reset-Results
        Invoke-AllSetup
        $summary = Write-Report -ReportAction 'setup-all'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'Master' {
        $exitCode = Invoke-MasterFlow
    }
    'CheckRuntimes' {
        Reset-Results
        Invoke-CheckRuntimes
        $summary = Write-Report -ReportAction 'check-runtimes'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'SetupRuntimes' {
        Reset-Results
        Invoke-SetupRuntimes
        $summary = Write-Report -ReportAction 'setup-runtimes'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'CheckPackages' {
        Reset-Results
        Invoke-CheckPackages
        $summary = Write-Report -ReportAction 'check-packages'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'SetupPackages' {
        Reset-Results
        Invoke-SetupPackages
        $summary = Write-Report -ReportAction 'setup-packages'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'CheckModules' {
        Reset-Results
        Invoke-CheckModules
        $summary = Write-Report -ReportAction 'check-modules'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'SetupModules' {
        Reset-Results
        Invoke-SetupModules
        $summary = Write-Report -ReportAction 'setup-modules'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'CheckRepositories' {
        Reset-Results
        Invoke-CheckRepositories
        $summary = Write-Report -ReportAction 'check-repositories'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'SetupRepositories' {
        Reset-Results
        Invoke-SetupRepositories
        $summary = Write-Report -ReportAction 'setup-repositories'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'CheckFeatures' {
        Reset-Results
        Invoke-CheckFeatures
        $summary = Write-Report -ReportAction 'check-features'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'SetupFeatures' {
        Reset-Results
        Invoke-SetupFeatures
        $summary = Write-Report -ReportAction 'setup-features'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'CheckEnvironment' {
        Reset-Results
        Invoke-CheckEnvironment
        $summary = Write-Report -ReportAction 'check-environment'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
    'SetupEnvironment' {
        Reset-Results
        Invoke-SetupEnvironment
        $summary = Write-Report -ReportAction 'setup-environment'
        if ($summary.Fail -gt 0) { $exitCode = 1 }
    }
}

exit $exitCode
