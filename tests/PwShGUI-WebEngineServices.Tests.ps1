# VersionTag: 2605.B5.V51.2
# SupportPS5.1: true
# SupportsPS7.6: true
# FileRole: Test
#Requires -Modules Pester

Set-StrictMode -Version Latest

Describe 'PwShGUI-WebEngineServices module' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:modulePath = Join-Path $script:repoRoot 'modules\PwShGUI-WebEngineServices.psm1'
        Import-Module -Name $script:modulePath -Force
    }

    It 'provides default component config with five components' {
        Initialize-WebEngineServicesModule -WorkspaceRoot $TestDrive -ServicePort 8042
        $cfg = Get-DefaultWebEngineServicesConfig

        $cfg.schema | Should -Be 'WebEngineServicesConfig/1.0'
        @($cfg.components).Count | Should -Be 5
    }

    It 'falls back to provided definitions when component config file is missing' {
        Initialize-WebEngineServicesModule -WorkspaceRoot $TestDrive -ServicePort 8042

        $fallback = @(
            [PSCustomObject]@{
                Name = 'UnitA'
                Path = 'scripts/UnitA.ps1'
                StartArgs = @()
                StatusHints = @('UnitA.ps1')
                ControlMode = 'toggle'
                ObjectVersion = '1.0.0'
                UpgradeScript = ''
                Enabled = $true
            }
        )

        $defs = @(Get-WebEngineServiceDefinitions -FallbackDefinitions $fallback)
        @($defs).Count | Should -Be 1
        @($defs)[0].Name | Should -Be 'UnitA'
    }

    It 'loads component definitions from config/webengine-services.components.json when present' {
        $cfgDir = Join-Path $TestDrive 'config'
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null

        $cfgPath = Join-Path $cfgDir 'webengine-services.components.json'
        $payload = [ordered]@{
            schema = 'WebEngineServicesConfig/1.0'
            components = @(
                [ordered]@{
                    componentId = 'unit-comp'
                    name = 'UnitComponent'
                    path = 'scripts/UnitComponent.ps1'
                    startArgs = @('-Quiet')
                    statusHints = @('UnitComponent.ps1')
                    enabled = $true
                    controlMode = 'toggle'
                    objectVersion = '1.2.3'
                    upgradeScript = ''
                }
            )
        }
        Set-Content -LiteralPath $cfgPath -Value ($payload | ConvertTo-Json -Depth 8) -Encoding UTF8 -Force

        Initialize-WebEngineServicesModule -WorkspaceRoot $TestDrive -ServicePort 8042
        $defs = @(Get-WebEngineServiceDefinitions)

        @($defs).Count | Should -Be 1
        @($defs)[0].Name | Should -Be 'UnitComponent'
        @($defs)[0].ObjectVersion | Should -Be '1.2.3'
    }

    It 'detects component config hot-reload changes' {
        $cfgDir = Join-Path $TestDrive 'config'
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        $cfgPath = Join-Path $cfgDir 'webengine-services.components.json'

        $payloadA = [ordered]@{ schema = 'WebEngineServicesConfig/1.0'; components = @() }
        Set-Content -LiteralPath $cfgPath -Value ($payloadA | ConvertTo-Json -Depth 5) -Encoding UTF8 -Force

        Initialize-WebEngineServicesModule -WorkspaceRoot $TestDrive -ServicePort 8042
        (Test-WebEngineServicesConfigChanged) | Should -BeFalse

        Start-Sleep -Milliseconds 1100
        $payloadB = [ordered]@{ schema = 'WebEngineServicesConfig/1.0'; components = @([ordered]@{ name='X'; path='scripts/X.ps1'; enabled=$true }) }
        Set-Content -LiteralPath $cfgPath -Value ($payloadB | ConvertTo-Json -Depth 5) -Encoding UTF8 -Force

        (Test-WebEngineServicesConfigChanged) | Should -BeTrue
        (Test-WebEngineServicesConfigChanged) | Should -BeFalse
    }
}
