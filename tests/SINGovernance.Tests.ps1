# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS  SINGovernance module Pester tests.
.DESCRIPTION
    Tests for SINGovernance.psm1: SIN review queue, approval workflow,
    governance state tracking, and registry integration.
    Requires Pester v5+.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\SINGovernance.psm1'
    Import-Module $modulePath -Force
}

Describe 'SINGovernance Module' {
    It 'Imports successfully' {
        Get-Module 'SINGovernance' | Should -Not -BeNullOrEmpty
    }
    It 'Exports 6 functions' {
        $exports = (Get-Module 'SINGovernance').ExportedFunctions.Keys
        $exports.Count | Should -Be 6
    }
}

Describe 'Get-SINReviewQueue' {
    It 'Returns queue data without error' {
        { Get-SINReviewQueue } | Should -Not -Throw
    }
}

