# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Pester unit tests for AVPN-Tracker module -- Pass 2 Module Coverage.
.DESCRIPTION
    Tests: Get-AVPNConnectorCount, Test-AVPNConnectionValid,
    Import/Export-AVPNCsv, Initialize-AVPNConfigFile, Get/Save-AVPNConfig.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\AVPN-Tracker.psm1'
    Import-Module $modulePath -Force

    # Also need internal functions -- dot-source for testing non-exported functions
    . $modulePath
}

Describe 'Get-AVPNDefaultTemplateList' {
    It 'Should return 15 device templates' {
        $templates = Get-AVPNDefaultTemplateList
        $templates.Count | Should -Be 15
    }

    It 'Should include required template fields' {
        $templates = Get-AVPNDefaultTemplateList
        $first = $templates[0]
        $first.id | Should -Not -BeNullOrEmpty
        $first.type | Should -Not -BeNullOrEmpty
        $first.model | Should -Not -BeNullOrEmpty
        $first.name | Should -Not -BeNullOrEmpty
    }

    It 'Template IDs should be sequential 1-15' {
        $templates = Get-AVPNDefaultTemplateList
        $ids = $templates | ForEach-Object { $_.id }
        $ids | Should -Be @(1..15)
    }
}

Describe 'Get-AVPNConnectorCount' {
    BeforeAll {
        $testDevice = @{
            avInputs = 4
            avOutputs = 2
            powerInputs = 1
            powerOutputs = 4
            networkInterfaces = 2
            usbInputs = 3
            usbPlugs = 1
        }
    }

    It 'Should return correct AV Input count' {
        Get-AVPNConnectorCount -Device $testDevice -ConnectorType 'AV Input' | Should -Be 4
    }

    It 'Should return correct AV Output count' {
        Get-AVPNConnectorCount -Device $testDevice -ConnectorType 'AV Output' | Should -Be 2
    }

    It 'Should return correct Power Input count' {
        Get-AVPNConnectorCount -Device $testDevice -ConnectorType 'Power Input' | Should -Be 1
    }

    It 'Should return correct Network count' {
        Get-AVPNConnectorCount -Device $testDevice -ConnectorType 'Network' | Should -Be 2
    }

    It 'Should return 0 for unknown connector type' {
        Get-AVPNConnectorCount -Device $testDevice -ConnectorType 'Unknown' | Should -Be 0
    }
}

Describe 'Test-AVPNConnectionValid' {
    It 'Network-to-Network should be valid' {
        Test-AVPNConnectionValid -SourceType 'Network' -DestType 'Network' | Should -Be $true
    }

    It 'AV Output-to-AV Input should be valid' {
        Test-AVPNConnectionValid -SourceType 'AV Output' -DestType 'AV Input' | Should -Be $true
    }

    It 'Power Output-to-Power Input should be valid' {
        Test-AVPNConnectionValid -SourceType 'Power Output' -DestType 'Power Input' | Should -Be $true
    }

    It 'USB Plug-to-USB Input should be valid' {
        Test-AVPNConnectionValid -SourceType 'USB Plug' -DestType 'USB Input' | Should -Be $true
    }

    It 'AV Input-to-AV Input should be invalid' {
        Test-AVPNConnectionValid -SourceType 'AV Input' -DestType 'AV Input' | Should -Be $false
    }

    It 'Power Input-to-Network should be invalid' {
        Test-AVPNConnectionValid -SourceType 'Power Input' -DestType 'Network' | Should -Be $false
    }
}

Describe 'Initialize-AVPNConfigFile' {
    It 'Should create config file at specified path' {
        $configPath = Join-Path $TestDrive 'avpn-config.json'
        Initialize-AVPNConfigFile -ConfigPath $configPath
        Test-Path $configPath | Should -Be $true
    }

    It 'Should create valid JSON' {
        $configPath = Join-Path $TestDrive 'avpn-config2.json'
        Initialize-AVPNConfigFile -ConfigPath $configPath
        $content = Get-Content $configPath -Raw
        { $content | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'Should include default device templates' {
        $configPath = Join-Path $TestDrive 'avpn-config3.json'
        Initialize-AVPNConfigFile -ConfigPath $configPath
        $data = Get-Content $configPath -Raw | ConvertFrom-Json
        $data.avpnDevices.Count | Should -Be 15
    }

    It 'Should not overwrite existing config' {
        $configPath = Join-Path $TestDrive 'avpn-existing.json'
        Set-Content -Path $configPath -Value '{"test":"existing"}' -Encoding UTF8
        Initialize-AVPNConfigFile -ConfigPath $configPath
        $data = Get-Content $configPath -Raw | ConvertFrom-Json
        $data.test | Should -Be 'existing'
    }
}

Describe 'Import-AVPNCsv / Export-AVPNCsv round-trip' {
    It 'Should export and re-import inventory data' {
        $inventory = @(
            [ordered]@{
                deviceId = 'dev-001'
                instanceId = 'inst-001'
                templateId = 1
                type = 'Network Switch'
                model = 'Test Switch'
                name = 'SW-01'
                quantity = 1
                location = 'Rack A'
                avInputs = 0
                avOutputs = 0
                powerInputs = 1
                powerOutputs = 0
                networkInterfaces = 24
                usbInputs = 0
                usbPlugs = 0
                urlLink = ''
                loginUser = ''
                loginPassword = ''
                connections = @()
            }
        )
        $connections = @(
            [pscustomobject]@{
                SourceInstance = 'inst-001'
                SourceConnector = 'Network'
                DestInstance = 'inst-002'
                DestConnector = 'Network'
            }
        )

        $csvPath = Join-Path $TestDrive 'avpn-roundtrip.csv'
        Export-AVPNCsv -Inventory $inventory -Connections $connections -Path $csvPath
        Test-Path $csvPath | Should -Be $true

        $imported = Import-AVPNCsv -Path $csvPath
        $imported.Inventory.Count | Should -Be 1
        $imported.Connections.Count | Should -Be 1
        $imported.Inventory[0].type | Should -Be 'Network Switch'
    }
}

Describe 'Protect-AVPNCredential / Unprotect-AVPNCredential' {
    It 'Should encrypt and decrypt a plaintext string' {
        $plain = 'TestPassword123'
        $encrypted = Protect-AVPNCredential -PlainText $plain
        $encrypted | Should -Not -Be $plain
        $encrypted | Should -BeLike 'DPAPI:*'

        $decrypted = Unprotect-AVPNCredential -Stored $encrypted
        $decrypted | Should -Be $plain
    }

    It 'Should return empty string for null input (encrypt)' {
        Protect-AVPNCredential -PlainText '' | Should -Be ''
    }

    It 'Should return non-DPAPI string unchanged (decrypt)' {
        Unprotect-AVPNCredential -Stored 'PlainText' | Should -Be 'PlainText'
    }
}


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




