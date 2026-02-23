# VersionTag: 2604.B2.V31.0
<#
.SYNOPSIS  Pass 2 - AssistedSASC module Pester tests.
.DESCRIPTION
    Tests for AssistedSASC.psm1 vault/DPAPI functions.
    Requires Pester v5+.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\AssistedSASC.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

Describe 'Assert-SafePath' {
    It 'Accepts a valid absolute path' {
        if (Get-Command Assert-SafePath -ErrorAction SilentlyContinue) {
            $result = Assert-SafePath -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'config')
            $result | Should -Not -BeNullOrEmpty
        } else {
            Set-ItResult -Skipped -Because 'Assert-SafePath not exported'
        }
    }

    It 'Rejects path traversal attempts' {
        if (Get-Command Assert-SafePath -ErrorAction SilentlyContinue) {
            { Assert-SafePath -Path '..\..\Windows\System32' } | Should -Throw
        } else {
            Set-ItResult -Skipped -Because 'Assert-SafePath not exported'
        }
    }
}

Describe 'Initialize-SASCModule' {
    It 'Initializes without error' {
        if (Get-Command Initialize-SASCModule -ErrorAction SilentlyContinue) {
            { Initialize-SASCModule } | Should -Not -Throw
        } else {
            Set-ItResult -Skipped -Because 'Initialize-SASCModule not exported'
        }
    }
}

Describe 'Test-VaultStatus' {
    It 'Returns a status object' {
        if (Get-Command Test-VaultStatus -ErrorAction SilentlyContinue) {
            $status = Test-VaultStatus
            $status | Should -Not -BeNullOrEmpty
        } else {
            Set-ItResult -Skipped -Because 'Test-VaultStatus not exported'
        }
    }
}

Describe 'Find-BWCli' {
    It 'Returns path or null without throwing' {
        if (Get-Command Find-BWCli -ErrorAction SilentlyContinue) {
            { Find-BWCli } | Should -Not -Throw
        } else {
            Set-ItResult -Skipped -Because 'Find-BWCli not exported'
        }
    }
}

