# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
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


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





