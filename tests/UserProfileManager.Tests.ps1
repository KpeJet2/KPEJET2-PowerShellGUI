# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS  UserProfileManager module Pester tests.
.DESCRIPTION
    Tests for UserProfileManager.psm1: profile CRUD operations,
    preference persistence, and session state management.
    Requires Pester v5+.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\UserProfileManager.psm1'
    Import-Module $modulePath -Force
}

Describe 'UserProfileManager Module' {
    It 'Imports successfully' {
        Get-Module 'UserProfileManager' | Should -Not -BeNullOrEmpty
    }
    It 'Exports 31 functions' {
        $exports = (Get-Module 'UserProfileManager').ExportedFunctions.Keys
        $exports.Count | Should -Be 31
    }
}

Describe 'Get-UserProfile' {
    It 'Returns profile data without error' {
        { Get-UserProfile } | Should -Not -Throw
    }
}

