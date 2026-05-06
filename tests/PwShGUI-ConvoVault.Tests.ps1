# VersionTag: 2604.B2.V32.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS  Pass 1 - ConvoVault module Pester tests (IMPL-20260405-004).
.DESCRIPTION
    Tests for PwShGUI-ConvoVault.psm1.
    Covers: Initialize-ConvoVaultKey, Protect-ConvoEntry + Get-ConvoEntries round-trip,
    Add-ConvoEntry / Export-ConvoBundle structure, Invoke-ConvoExchange return type.
    Requires Pester v5+.
#>

BeforeAll {
    $ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\PwShGUI-ConvoVault.psm1'
    if (-not (Test-Path $ModulePath)) { throw "Module not found: $ModulePath" }
    Import-Module $ModulePath -Force

    # Use a throwaway temp directory for all vault I/O
    $script:TempVault = Join-Path $env:TEMP "ConvoVaultTest-$(Get-Random)"
    New-Item -Path $script:TempVault -ItemType Directory -Force | Out-Null
}

AfterAll {
    Remove-Module 'PwShGUI-ConvoVault' -ErrorAction SilentlyContinue
    if (Test-Path $script:TempVault) { Remove-Item $script:TempVault -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Initialize-ConvoVaultKey' {
    It 'does not throw when called with a temp path' {
        { Initialize-ConvoVaultKey -VaultPath $script:TempVault -ErrorAction Stop } | Should -Not -Throw
    }
}

Describe 'Protect-ConvoData / Unprotect-ConvoData round-trip' {
    It 'encrypts and decrypts a string' {
        $plain = 'Hello ConvoVault'
        $enc = Protect-ConvoData -Data $plain
        $enc | Should -Not -BeNullOrEmpty
        $dec = Unprotect-ConvoData -EncryptedData $enc
        $dec | Should -Be $plain
    }
}

Describe 'Protect-ConvoEntry' {
    It 'does not throw for a simple entry' {
        { Protect-ConvoEntry -Entry 'Test entry payload' } | Should -Not -Throw
    }
}

Describe 'Add-ConvoEntry / Get-ConvoEntries round-trip' {
    It 'adds and retrieves at least one entry' {
        Add-ConvoEntry -Message 'UnitTest message' -VaultPath $script:TempVault
        $entries = Get-ConvoEntries -VaultPath $script:TempVault
        @($entries).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'Export-ConvoBundle' {
    It 'exports bundle file to temp path' {
        $bundleDest = Join-Path $script:TempVault 'bundle-test.json'
        Export-ConvoBundle -Destination $bundleDest -VaultPath $script:TempVault
        Test-Path $bundleDest | Should -BeTrue
    }
}

Describe 'Invoke-ConvoExchange' {
    It 'returns a result object without throwing' {
        { $r = Invoke-ConvoExchange -Prompt 'ping' -VaultPath $script:TempVault; $r | Should -Not -BeNullOrEmpty } | Should -Not -Throw
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




