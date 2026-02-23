# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS  SASC-Adapters module Pester tests.
.DESCRIPTION
    Tests for SASC-Adapters.psm1: adapter registration, credential bridging,
    and external service integration patterns.
    Requires Pester v5+.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\SASC-Adapters.psm1'
    Import-Module $modulePath -Force
}

Describe 'SASC-Adapters Module' {
    It 'Imports successfully' {
        Get-Module 'SASC-Adapters' | Should -Not -BeNullOrEmpty
    }
    It 'Exports 8 functions' {
        $exports = (Get-Module 'SASC-Adapters').ExportedFunctions.Keys
        $exports.Count | Should -Be 8
    }
}

Describe 'Get-SASCAdapterList' {
    It 'Returns adapter list without error' {
        { Get-SASCAdapterList } | Should -Not -Throw
    }
}

