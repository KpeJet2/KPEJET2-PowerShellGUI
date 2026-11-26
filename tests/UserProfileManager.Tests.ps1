# VersionTag: 2607.B7.V53.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
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

Describe 'Encrypted profile snapshots' {
    It 'Rejects a password whose suffix differs from the original password' {
        $snapshot = @{
            Meta = @{ ProfileName = 'unicode-password-test' }
            Data = @{ Theme = 'Dark' }
        }
        $path = Join-Path $TestDrive 'profile.upjson'
        $original = ConvertTo-SecureString 'Pässword-一' -AsPlainText -Force
        $different = ConvertTo-SecureString 'Pässword-二' -AsPlainText -Force

        Save-ProfileSnapshot -Snapshot $snapshot -OutputPath $path -Encrypt $true -Password $original

        { Import-ProfileSnapshot -FilePath $path -Password $different } | Should -Throw
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







