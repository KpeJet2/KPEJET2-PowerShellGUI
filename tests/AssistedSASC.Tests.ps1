# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
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
    $script:WorkspaceRoot = Split-Path -Parent $PSScriptRoot
    # Pre-initialise the module so $script:_ModuleRoot is populated for Assert-SafePath default roots.
    if (Get-Command Initialize-SASCModule -ErrorAction SilentlyContinue) {
        try { Initialize-SASCModule -ScriptDir $script:WorkspaceRoot | Out-Null } catch { <# Intentional: non-fatal — SASC init is best-effort in test BeforeAll #> }
    }
}

Describe 'Assert-SafePath' {
    It 'Accepts a valid absolute path' {
        if (Get-Command Assert-SafePath -ErrorAction SilentlyContinue) {
            $configPath = Join-Path $script:WorkspaceRoot 'config'
            $result = Assert-SafePath -Path $configPath -AllowedRoots @($script:WorkspaceRoot)
            $result | Should -Not -BeNullOrEmpty
        } else {
            Set-ItResult -Skipped -Because 'Assert-SafePath not exported'
        }
    }

    It 'Rejects path traversal attempts' {
        if (Get-Command Assert-SafePath -ErrorAction SilentlyContinue) {
            { Assert-SafePath -Path '..\..\Windows\System32' -AllowedRoots @($script:WorkspaceRoot) } | Should -Throw
        } else {
            Set-ItResult -Skipped -Because 'Assert-SafePath not exported'
        }
    }
}

Describe 'Initialize-SASCModule' {
    It 'Initializes without error' {
        if (Get-Command Initialize-SASCModule -ErrorAction SilentlyContinue) {
            { Initialize-SASCModule -ScriptDir $script:WorkspaceRoot } | Should -Not -Throw
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


<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>





