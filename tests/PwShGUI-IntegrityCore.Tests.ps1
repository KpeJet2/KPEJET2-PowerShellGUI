# VersionTag: 2604.B2.V32.0
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

Describe 'Write-IntegrityLog' {
    It 'does not throw when writing a log entry' {
        $logPath = Join-Path $script:TempDir 'integrity.log'
        { Write-IntegrityLog -Message 'Pester test' -LogPath $logPath } | Should -Not -Throw
    }

    It 'creates the log file' {
        $logPath = Join-Path $script:TempDir 'integrity-created.log'
        Write-IntegrityLog -Message 'Pester test' -LogPath $logPath
        Test-Path $logPath | Should -BeTrue
    }
}

Describe 'Test-IntegrityManifest' {
    It 'returns false or throws for a non-existent manifest path' {
        $result = Test-IntegrityManifest -ManifestPath (Join-Path $script:TempDir 'nonexistent.json') -ErrorAction SilentlyContinue
        (-not $result) | Should -BeTrue
    }

    It 'accepts a valid empty JSON manifest without throwing' {
        $mPath = Join-Path $script:TempDir 'manifest.json'
        '{}' | Set-Content -Path $mPath -Encoding UTF8
        { Test-IntegrityManifest -ManifestPath $mPath } | Should -Not -Throw
    }
}

Describe 'Invoke-StartupIntegrityCheck' {
    It 'returns an object with a Status or Passed property' {
        $result = Invoke-StartupIntegrityCheck -WorkspacePath $script:TempDir -Silent
        $hasKey = $result.PSObject.Properties.Name -match 'Status|Passed|Success|Result'
        [bool]$hasKey | Should -BeTrue
    }
}

Describe 'Initialize-EmergencyUnlockKey' {
    It 'does not throw when called with a temp output path' {
        $keyPath = Join-Path $script:TempDir 'emergency.key'
        { Initialize-EmergencyUnlockKey -OutputPath $keyPath } | Should -Not -Throw
    }
}
