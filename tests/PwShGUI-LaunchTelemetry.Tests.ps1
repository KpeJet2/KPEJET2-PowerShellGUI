# VersionTag: 2607.B7.V53.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS  Pass 1 - LaunchTelemetry module Pester tests (IMPL-20260405-004).
.DESCRIPTION
    Tests for Get-LaunchTelemetry.psm1.
    Covers: Get-LaunchTelemetry return shape, mandatory keys, elapsed-time type.
    Requires Pester v5+.
#>

BeforeAll {
    $ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\Get-LaunchTelemetry.psm1'
    if (-not (Test-Path $ModulePath)) { throw "Module not found: $ModulePath" }
    Import-Module $ModulePath -Force
}

AfterAll {
    Remove-Module 'Get-LaunchTelemetry' -ErrorAction SilentlyContinue
}

Describe 'Get-LaunchTelemetry' {

    BeforeAll {
        $script:TelemetryArgs = @{
            BatchName  = 'Launch-GUI.bat'
            VersionTag = '2607.B7.V53.0'
            BatchPath  = 'C:\PowerShellGUI\Launch-GUI.bat'
        }
    }

    Context 'Return type' {
        It 'returns an object' {
            $result = Get-LaunchTelemetry @script:TelemetryArgs
            $result | Should -Not -BeNullOrEmpty
        }

        It 'result is a PSCustomObject' {
            $result = Get-LaunchTelemetry @script:TelemetryArgs
            $result.GetType().Name | Should -Be 'PSCustomObject'
        }
    }

    Context 'Required keys' {
        BeforeAll { $script:Telemetry = Get-LaunchTelemetry @script:TelemetryArgs }

        It 'has all 14 documented telemetry properties' {
            $expected = @('Timestamp','BatchName','VersionTag','MachineName','Username','IPAddress',
                'BatchPath','SystemVolume','SystemVolFreeSpace','MemoryUsedOfTotal','CPULoad',
                'GPULoad','TotalProcesses','IsAdmin')
            $actual = @($script:Telemetry.PSObject.Properties.Name)
            foreach ($name in $expected) { $actual | Should -Contain $name }
        }

        It 'echoes the caller-supplied batch parameters' {
            $script:Telemetry.BatchName  | Should -Be $script:TelemetryArgs.BatchName
            $script:Telemetry.VersionTag | Should -Be $script:TelemetryArgs.VersionTag
            $script:Telemetry.BatchPath  | Should -Be $script:TelemetryArgs.BatchPath
        }
    }

    Context 'Edge cases' {
        It 'does not throw on repeated calls' {
            { Get-LaunchTelemetry @script:TelemetryArgs; Get-LaunchTelemetry @script:TelemetryArgs } | Should -Not -Throw
        }
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







