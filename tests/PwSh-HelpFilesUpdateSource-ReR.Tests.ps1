# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS  PwSh-HelpFilesUpdateSource-ReR module Pester tests.
.DESCRIPTION
    Tests for PwSh-HelpFilesUpdateSource-ReR.psm1: help file generation,
    source reconciliation, and ReR (Read-Extract-Render) pipeline.
    Requires Pester v5+.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\PwSh-HelpFilesUpdateSource-ReR.psm1'
    Import-Module $modulePath -Force
}

Describe 'PwSh-HelpFilesUpdateSource-ReR Module' {
    It 'Imports successfully' {
        Get-Module 'PwSh-HelpFilesUpdateSource-ReR' | Should -Not -BeNullOrEmpty
    }
    It 'Exports 7 functions' {
        $exports = (Get-Module 'PwSh-HelpFilesUpdateSource-ReR').ExportedFunctions.Keys
        $exports.Count | Should -Be 7
    }
}

Describe 'Update-HelpSource' {
    It 'Runs without error when given valid path' {
        { Update-HelpSource -Path $TestDrive } | Should -Not -Throw
    }
}

