#Requires -Version 5.1
# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
    PwShGUI-VersionManager.Tests.ps1
    Pester v5 tests for PwShGUI-VersionManager module
    Tests: Parse-VersionTag, Format-VersionTag, Get/Set-FileVersion,
           Step-MinorVersion, CPSR action persistence, epoch save/load
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\PwShGUI-VersionManager.psm1'
    Import-Module $modulePath -Force -DisableNameChecking
    $testWorkspace = Join-Path $env:TEMP 'PwShGUI-VersionManager-Tests'
    if (Test-Path $testWorkspace) { Remove-Item $testWorkspace -Recurse -Force }
    New-Item -ItemType Directory -Path $testWorkspace -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testWorkspace 'temp') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testWorkspace 'checkpoints') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testWorkspace '~REPORTS\CPSR') -Force | Out-Null
}

AfterAll {
    $testWorkspace = Join-Path $env:TEMP 'PwShGUI-VersionManager-Tests'
    if (Test-Path $testWorkspace) { Remove-Item $testWorkspace -Recurse -Force }
}

Describe 'Parse-VersionTag' {
    It 'Parses new V-format tag with minor .0' {
        $result = Parse-VersionTag -Tag '2604.B1.V1.0'
        $result.major | Should -Be 1
        $result.minor | Should -Be 0
        $result.isZeroNull | Should -Be $false
        $result.prefix | Should -Be '2604.B1'
    }

    It 'Parses V-format tag with non-zero minor' {
        $result = Parse-VersionTag -Tag '2604.B1.V1.3'
        $result.major | Should -Be 1
        $result.minor | Should -Be 3
        $result.isZeroNull | Should -Be $false
    }

    It 'Parses legacy lowercase v tag (backward compat)' {
        $result = Parse-VersionTag -Tag '2603.B0.v27.0'
        $result.major | Should -Be 27
        $result.minor | Should -Be 0
        $result.prefix | Should -Be '2603.B0'
    }

    It 'Parses tag with different build prefix' {
        $result = Parse-VersionTag -Tag '2601.B1.V10.5'
        $result.major | Should -Be 10
        $result.minor | Should -Be 5
        $result.prefix | Should -Be '2601.B1'
    }

    It 'Returns null for invalid tag' {
        $result = Parse-VersionTag -Tag 'not-a-version'
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Format-VersionTag' {
    It 'Formats tag with uppercase V and minor .0' {
        $tag = Format-VersionTag -Prefix '2604.B1' -Major 1 -Minor 0
        $tag | Should -Be '2604.B1.V1.0'
    }

    It 'Formats tag with non-zero minor' {
        $tag = Format-VersionTag -Prefix '2604.B1' -Major 1 -Minor 5
        $tag | Should -Be '2604.B1.V1.5'
    }

    It 'Uses script default prefix when none specified' {
        $tag = Format-VersionTag -Major 1 -Minor 0
        $tag | Should -Match '^\d{4}\.B\d+\.V\d+\.\d+$'
    }
}

Describe 'Get-FileVersion / Set-FileVersion' {
    BeforeEach {
        $testFile = Join-Path $env:TEMP "version-test-$(Get-Random).psm1"
        Set-Content -Path $testFile -Value "# VersionTag: 2604.B2.V31.2`nfunction Test-Something { }" -Encoding UTF8
    }

    AfterEach {
        if (Test-Path $testFile) { Remove-Item $testFile -Force }
    }

    It 'Reads version from file with V-format tag' {
        $ver = Get-FileVersion -FilePath $testFile
        $ver.major | Should -Be 1
        $ver.minor | Should -Be 0
    }

    It 'Writes new version tag to file' {
        Set-FileVersion -FilePath $testFile -NewTag '2604.B1.V1.0'
        $line = Select-String -Path $testFile -Pattern 'VersionTag' | Select-Object -First 1
        $line.Line | Should -BeLike '* 2604.B1.V1.0*'
    }
}

Describe 'Step-MinorVersion' {
    BeforeEach {
        $testFile = Join-Path $env:TEMP "step-minor-test-$(Get-Random).psm1"
        Set-Content -Path $testFile -Value "# VersionTag: 2604.B2.V31.2`nfunction Test-Bump { }" -Encoding UTF8
    }

    AfterEach {
        if (Test-Path $testFile) { Remove-Item $testFile -Force }
    }

    It 'Increments minor version by 1' {
        Step-MinorVersion -FilePath $testFile
        $ver = Get-FileVersion -FilePath $testFile
        $ver.minor | Should -Be 1
    }

    It 'Increments minor from higher value' {
        Set-FileVersion -FilePath $testFile -NewTag '2604.B1.V1.5'
        Step-MinorVersion -FilePath $testFile
        $ver = Get-FileVersion -FilePath $testFile
        $ver.minor | Should -Be 6
    }
}

Describe 'CPSR Action Persistence' {
    BeforeEach {
        $sessionFile = Join-Path $env:TEMP 'cpsr-actions-session.json'
        $sessionIdFile = Join-Path $env:TEMP 'cpsr-session-id.txt'
        if (Test-Path $sessionFile) { Remove-Item $sessionFile -Force }
        if (Test-Path $sessionIdFile) { Remove-Item $sessionIdFile -Force }
    }

    It 'Persists actions to file-backed JSON' {
        Add-CPSRAction -Action 'TEST_ACTION' -Agent 'TestAgent' -ItemId 'item-1' -ItemType 'Test' -VersionBefore 'v1' -VersionAfter 'v2' -Detail 'test detail'
        $lines = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'temp\cpsr-actions-session.json')
        $lastLine = $lines[-1] | ConvertFrom-Json
        $lastLine.action | Should -Be 'TEST_ACTION'
    }
}

Describe 'Save-PipelineEpoch / Get-LatestEpoch' {
    It 'Saves epoch JSON and returns path' {
        $ws = Join-Path $env:TEMP 'PwShGUI-VersionManager-Tests'
        $result = Save-PipelineEpoch -WorkspacePath $ws -Phase 'TestPhase' -Description 'Test epoch'
        $result.epochId | Should -Not -BeNullOrEmpty
        $result.path | Should -Not -BeNullOrEmpty
        Test-Path $result.path | Should -Be $true
    }

    It 'Epoch JSON contains required fields' {
        $ws = Join-Path $env:TEMP 'PwShGUI-VersionManager-Tests'
        $result = Save-PipelineEpoch -WorkspacePath $ws -Phase 'FieldCheck' -Description 'Fields test'
        $epoch = Get-Content $result.path -Raw | ConvertFrom-Json
        $epoch.epochId | Should -Not -BeNullOrEmpty
        $epoch.phase | Should -Be 'FieldCheck'
        $epoch.description | Should -Be 'Fields test'
        $epoch.versionState | Should -Not -BeNullOrEmpty
    }

    It 'Get-LatestEpoch returns most recent' {
        $ws = Join-Path $env:TEMP 'PwShGUI-VersionManager-Tests'
        $result = Get-LatestEpoch -WorkspacePath $ws
        $result | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-WorkspaceVersionInventory' {
    It 'Returns version info for workspace files' {
        $ws = (Split-Path -Parent $PSScriptRoot)
        $inv = Get-WorkspaceVersionInventory -WorkspacePath $ws
        @($inv).Count | Should -BeGreaterThan 0
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




