# VersionTag: 2604.B2.V32.2
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

    Context 'Return type' {
        It 'returns an object' {
            $result = Get-LaunchTelemetry
            $result | Should -Not -BeNullOrEmpty
        }

        It 'result is a PSCustomObject or hashtable' {
            $result = Get-LaunchTelemetry
            $result.GetType().Name | Should -BeIn @('PSCustomObject', 'Hashtable', 'OrderedDictionary')
        }
    }

    Context 'Required keys' {
        BeforeAll { $script:Telemetry = Get-LaunchTelemetry }

        It 'has a TotalElapsedMs or ElapsedMs key' {
            $has = ($script:Telemetry.PSObject.Properties.Name -match 'Elapsed' -or
                    ($script:Telemetry -is [hashtable] -and ($script:Telemetry.Keys -match 'Elapsed').Count -gt 0))
            $has | Should -BeTrue
        }

        It 'elapsed value is numeric' {
            $key = $script:Telemetry.PSObject.Properties.Name | Where-Object { $_ -match 'Elapsed' } | Select-Object -First 1
            if ($key) {
                { [double]$script:Telemetry.$key } | Should -Not -Throw
            }
        }
    }

    Context 'Edge cases' {
        It 'does not throw on repeated calls' {
            { Get-LaunchTelemetry; Get-LaunchTelemetry } | Should -Not -Throw
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




