# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS  PwShGUI_AutoIssueFinder module Pester tests.
.DESCRIPTION
    Tests for PwShGUI_AutoIssueFinder.psm1: automated issue detection,
    pattern scanning, and issue reporting.
    Requires Pester v5+.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\PwShGUI_AutoIssueFinder.psm1'
    Import-Module $modulePath -Force
}

Describe 'PwShGUI_AutoIssueFinder Module' {
    It 'Imports successfully' {
        Get-Module 'PwShGUI_AutoIssueFinder' | Should -Not -BeNullOrEmpty
    }
    It 'Exports 1 function' {
        $exports = (Get-Module 'PwShGUI_AutoIssueFinder').ExportedFunctions.Keys
        $exports.Count | Should -Be 1
    }
}

Describe 'Invoke-PwShGUIAutoIssueFinder' {
    It 'Returns scan results without error' {
        { Invoke-PwShGUIAutoIssueFinder } | Should -Not -Throw
    }
}

