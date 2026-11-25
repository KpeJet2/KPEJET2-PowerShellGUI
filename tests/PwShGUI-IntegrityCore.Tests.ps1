# VersionTag: 2607.B7.V53.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS  Pass 1 - IntegrityCore module Pester tests (IMPL-20260405-004).
.DESCRIPTION
    Tests for PwShGUI-IntegrityCore.psm1.
    Covers: Write-IntegrityLog, Test-IntegrityManifest (valid/invalid),
    Invoke-StartupIntegrityCheck shape, emergency key init contracts.
    Requires Pester v5+.
#>

BeforeAll {
    $ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\PwShGUI-IntegrityCore.psm1'
    if (-not (Test-Path $ModulePath)) { throw "Module not found: $ModulePath" }
    Import-Module $ModulePath -Force

    $script:TempDir = Join-Path $env:TEMP "IntegrityCoreTest-$(Get-Random)"
    New-Item -Path $script:TempDir -ItemType Directory -Force | Out-Null
}

AfterAll {
    Remove-Module 'PwShGUI-IntegrityCore' -ErrorAction SilentlyContinue
    if (Test-Path $script:TempDir) { Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Test-IntegrityManifest' {
    It 'skips with Passed = true when the manifest path does not exist' {
        $result = Test-IntegrityManifest -WorkspacePath $script:TempDir -ManifestPath (Join-Path $script:TempDir 'nonexistent.json')
        $result.Passed  | Should -BeTrue
        $result.Skipped | Should -BeTrue
    }

    It 'accepts a valid empty JSON manifest without throwing' {
        $mPath = Join-Path $script:TempDir 'manifest.json'
        '[]' | Set-Content -Path $mPath -Encoding UTF8
        { Test-IntegrityManifest -WorkspacePath $script:TempDir -ManifestPath $mPath } | Should -Not -Throw
    }

    It 'reports a violation for a file missing from the workspace' {
        $mPath = Join-Path $script:TempDir 'manifest-missing.json'
        '[{"RelativePath":"missing.txt","Hash":"ABC"}]' | Set-Content -Path $mPath -Encoding UTF8
        $result = Test-IntegrityManifest -WorkspacePath $script:TempDir -ManifestPath $mPath
        $result.Passed         | Should -BeFalse
        $result.ViolationCount | Should -Be 1
    }
}

Describe 'Invoke-StartupIntegrityCheck' {
    It 'returns Passed, Issues and IssueCount' {
        $result = Invoke-StartupIntegrityCheck -WorkspacePath $script:TempDir
        $result.PSObject.Properties.Name | Should -Contain 'Passed'
        $result.PSObject.Properties.Name | Should -Contain 'Issues'
        $result.PSObject.Properties.Name | Should -Contain 'IssueCount'
    }

    It 'fails when required workspace directories are missing' {
        $result = Invoke-StartupIntegrityCheck -WorkspacePath $script:TempDir
        $result.Passed | Should -BeFalse
    }
}

Describe 'Initialize-EmergencyUnlockKey' {
    It 'requires a WorkspacePath parameter' {
        (Get-Command Initialize-EmergencyUnlockKey).Parameters.Keys | Should -Contain 'WorkspacePath'
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







