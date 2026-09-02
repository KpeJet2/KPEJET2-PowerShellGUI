# VersionTag: 2607.B7.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
# SupportPS5.1TestedDate: 2026-05-25
# SupportsPS7.6TestedDate: 2026-05-25
# FileRole: Module
# Web engine services component registry, hot-reload detection, and upgrade helpers.
#Requires -Version 5.1

Set-StrictMode -Version Latest

$script:WorkspacePath = $null
$script:Port = 8042
$script:ConfigPath = $null
$script:ConfigFingerprint = ''
$script:WriteLog = $null

function Write-WebEngineServicesLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','ACTION','PASS','DEBUG')] [string]$Level = 'INFO'
    )

    if ($null -ne $script:WriteLog -and $script:WriteLog -is [scriptblock]) {
        try {
            & $script:WriteLog $Message $Level
            return
        } catch {
            <# Intentional: non-fatal fallback to host output #>
        }
    }

    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

function Initialize-WebEngineServicesModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspaceRoot,
        [int]$ServicePort = 8042,
        [AllowNull()] [scriptblock]$WriteLogScript = $null
    )

    $script:WorkspacePath = [System.IO.Path]::GetFullPath($WorkspaceRoot)
    $script:Port = $ServicePort
    $script:ConfigPath = Join-Path (Join-Path $script:WorkspacePath 'config') 'webengine-services.components.json'
    $script:WriteLog = $WriteLogScript
    $script:ConfigFingerprint = Get-WebEngineServicesConfigFingerprint
}

function Get-WebEngineServicesConfigPath {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($script:ConfigPath)) {
        return ''
    }
    return $script:ConfigPath
}

function Get-DefaultWebEngineServicesConfig {
    [CmdletBinding()]
    param()

    return [ordered]@{
        schema = 'WebEngineServicesConfig/1.0'
        _versionTag = '2605.B5.V51.2'
        components = @(
            [ordered]@{
                componentId = 'svc-cluster-dashboard'
                name = 'ServiceClusterDashboard'
                path = 'scripts/service-cluster-dashboard/Launch-ServiceClusterDashboard.bat'
                startArgs = @()
                statusHints = @('Launch-ServiceClusterDashboard.bat','uvicorn server:app','--port 8099')
                enabled = $true
                controlMode = 'toggle'
                objectVersion = '1.0.0'
                upgradeScript = ''
            },
            [ordered]@{
                componentId = 'engine-bootstrap'
                name = 'EngineBootstrap'
                path = 'scripts/Start-Engines.ps1'
                startArgs = @('-Quiet')
                statusHints = @('Start-Engines.ps1')
                enabled = $true
                controlMode = 'toggle'
                objectVersion = '1.0.0'
                upgradeScript = ''
            },
            [ordered]@{
                componentId = 'engine-monitor'
                name = 'Start-EngineServiceMonitor'
                path = 'scripts/Invoke-EngineServiceMonitor.ps1'
                startArgs = @('/AUTO','-Quiet')
                statusHints = @('Invoke-EngineServiceMonitor.ps1','engine-monitor')
                enabled = $true
                controlMode = 'toggle'
                objectVersion = '1.0.0'
                upgradeScript = ''
            },
            [ordered]@{
                componentId = 'cron-processor-1'
                name = 'Invoke-CronProcessor.ps1 #1'
                path = 'scripts/Invoke-CronProcessor.ps1'
                startArgs = @()
                statusHints = @('Invoke-CronProcessor.ps1')
                enabled = $true
                controlMode = 'toggle'
                objectVersion = '1.0.0'
                upgradeScript = ''
            },
            [ordered]@{
                componentId = 'cron-processor-2'
                name = 'Invoke-CronProcessor.ps1 #2'
                path = 'scripts/Invoke-CronProcessor.ps1'
                startArgs = @()
                statusHints = @('Invoke-CronProcessor.ps1')
                enabled = $true
                controlMode = 'toggle'
                objectVersion = '1.0.0'
                upgradeScript = ''
            }
        )
    }
}

function Get-WebEngineServicesConfigFingerprint {
    [CmdletBinding()]
    param()

    $path = Get-WebEngineServicesConfigPath
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return 'missing'
    }

    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        return ("{0}|{1}" -f $item.LastWriteTimeUtc.Ticks, $item.Length)
    } catch {
        return 'error'
    }
}

function Test-WebEngineServicesConfigChanged {
    [CmdletBinding()]
    param()

    $current = Get-WebEngineServicesConfigFingerprint
    if ([string]::IsNullOrWhiteSpace($script:ConfigFingerprint)) {
        $script:ConfigFingerprint = $current
        return $false
    }

    if ($current -ne $script:ConfigFingerprint) {
        $script:ConfigFingerprint = $current
        return $true
    }

    return $false
}

function ConvertTo-WebEngineServiceDefinitions {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]]$Components)

    $defs = [System.Collections.ArrayList]@()
    foreach ($c in @($Components)) {
        if ($null -eq $c) { continue }

        $enabled = if ($c.PSObject.Properties.Name -contains 'enabled') { [bool]$c.enabled } else { $true }
        if (-not $enabled) { continue }

        $name = if ($c.PSObject.Properties.Name -contains 'name') { [string]$c.name } else { '' }
        $path = if ($c.PSObject.Properties.Name -contains 'path') { [string]$c.path } else { '' }
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($path)) { continue }

        $componentStartList = @()
        if ($c.PSObject.Properties.Name -contains 'startArgs') {
            $componentStartList = @($c.startArgs | ForEach-Object { [string]$_ })
        }

        $statusHints = @()
        if ($c.PSObject.Properties.Name -contains 'statusHints') {
            $statusHints = @($c.statusHints | ForEach-Object { [string]$_ })
        }
        if (@($statusHints).Count -eq 0) {
            $statusHints = @([System.IO.Path]::GetFileName($path))
        }

        $componentId = if ($c.PSObject.Properties.Name -contains 'componentId') { [string]$c.componentId } else { $name }
        $controlMode = if ($c.PSObject.Properties.Name -contains 'controlMode') { [string]$c.controlMode } else { 'toggle' }
        $objectVersion = if ($c.PSObject.Properties.Name -contains 'objectVersion') { [string]$c.objectVersion } else { '1.0.0' }
        $upgradeScript = if ($c.PSObject.Properties.Name -contains 'upgradeScript') { [string]$c.upgradeScript } else { '' }

        [void]$defs.Add([PSCustomObject]@{
            Name = $name
            Path = $path
            StartArgs = $componentStartList
            StatusHints = $statusHints
            ComponentId = $componentId
            ControlMode = $controlMode
            ObjectVersion = $objectVersion
            UpgradeScript = $upgradeScript
            Enabled = $enabled
        })
    }

    return @($defs)
}

function Get-WebEngineServiceDefinitions {
    [CmdletBinding()]
    param([AllowNull()] [object[]]$FallbackDefinitions = @())

    $cfgPath = Get-WebEngineServicesConfigPath
    if (-not [string]::IsNullOrWhiteSpace($cfgPath) -and (Test-Path -LiteralPath $cfgPath -PathType Leaf)) {
        try {
            $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $cfg -and $cfg.PSObject.Properties.Name -contains 'components') {
                    $defsFromCfg = ConvertTo-WebEngineServiceDefinitions -Components @($cfg.components)
                    if (@($defsFromCfg).Count -gt 0) {
                        return $defsFromCfg
                    }
                }
            }
        } catch {
            Write-WebEngineServicesLog -Level 'WARN' -Message ("Component config parse failed: {0}" -f $_.Exception.Message)
        }
    }

    if (@($FallbackDefinitions).Count -gt 0) {
        return @($FallbackDefinitions)
    }

    $defaults = Get-DefaultWebEngineServicesConfig
    return (ConvertTo-WebEngineServiceDefinitions -Components @($defaults.components))
}

function Invoke-WebEngineComponentUpgrade {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Definition,
        [switch]$Quiet
    )

    $name = if ($Definition.PSObject.Properties.Name -contains 'Name') { [string]$Definition.Name } else { '' }
    $upgradeScript = if ($Definition.PSObject.Properties.Name -contains 'UpgradeScript') { [string]$Definition.UpgradeScript } else { '' }
    if ([string]::IsNullOrWhiteSpace($name)) {
        return [PSCustomObject]@{ Name = ''; Success = $false; Message = 'Invalid component definition.' }
    }

    if ([string]::IsNullOrWhiteSpace($upgradeScript)) {
        return [PSCustomObject]@{ Name = $name; Success = $false; Message = 'No upgrade script configured.' }
    }

    $fullUpgrade = if ([System.IO.Path]::IsPathRooted($upgradeScript)) { $upgradeScript } else { Join-Path $script:WorkspacePath $upgradeScript }
    if (-not (Test-Path -LiteralPath $fullUpgrade -PathType Leaf)) {
        return [PSCustomObject]@{ Name = $name; Success = $false; Message = ("Upgrade script not found: {0}" -f $fullUpgrade) }
    }

    $hostExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } elseif (Get-Command powershell.exe -ErrorAction SilentlyContinue) { 'powershell.exe' } else { '' }
    if ([string]::IsNullOrWhiteSpace($hostExe)) {
        return [PSCustomObject]@{ Name = $name; Success = $false; Message = 'No PowerShell host executable found.' }
    }

    try {
        $tempOut = [System.IO.Path]::GetTempFileName()
        try {
            $escapedScript = $fullUpgrade.Replace('"', '""')
            $escapedWorkspace = $script:WorkspacePath.Replace('"', '""')
            $argText = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -WorkspacePath "{1}"' -f $escapedScript, $escapedWorkspace)
            $proc = Start-Process -FilePath $hostExe -ArgumentList $argText -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $tempOut -RedirectStandardError $tempOut
            $exitCode = [int]$proc.ExitCode
            $output = @()
            if (Test-Path -LiteralPath $tempOut -PathType Leaf) {
                $output = @(Get-Content -LiteralPath $tempOut -Encoding UTF8 -ErrorAction SilentlyContinue)
            }
        } finally {
            if (Test-Path -LiteralPath $tempOut -PathType Leaf) {
                Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
            }
        }
        if ($exitCode -eq 0) {
            if (-not $Quiet) {
                Write-WebEngineServicesLog -Level 'PASS' -Message ("Component upgrade succeeded: {0}" -f $name)
            }
            return [PSCustomObject]@{ Name = $name; Success = $true; Message = 'Upgrade completed.'; ExitCode = $exitCode; Output = ($output -join ' | ') }
        }

        return [PSCustomObject]@{ Name = $name; Success = $false; Message = 'Upgrade script failed.'; ExitCode = $exitCode; Output = ($output -join ' | ') }
    } catch {
        return [PSCustomObject]@{ Name = $name; Success = $false; Message = $_.Exception.Message }
    }
}

Export-ModuleMember -Function @(
    'Initialize-WebEngineServicesModule',
    'Get-WebEngineServicesConfigPath',
    'Get-DefaultWebEngineServicesConfig',
    'Get-WebEngineServicesConfigFingerprint',
    'Test-WebEngineServicesConfigChanged',
    'Get-WebEngineServiceDefinitions',
    'Invoke-WebEngineComponentUpgrade'
)


