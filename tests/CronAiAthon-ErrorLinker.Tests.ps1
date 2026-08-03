# VersionTag: 2607.B7.V54.0
# SupportPS5.1: YES(As of: 2026-07-28)
# SupportsPS7.6: YES(As of: 2026-07-28)
# SupportPS5.1TestedDate: 2026-07-28
# SupportsPS7.6TestedDate: 2026-07-28
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:RepoRoot 'modules\CronAiAthon-Pipeline.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'modules\CronAiAthon-ErrorLinker.psm1') -Force

    function New-ErrorLinkerWorkspace {
        param([string]$Name)

        $ws = Join-Path $TestDrive $Name
        foreach ($dirName in @('config', 'todo', 'logs', 'temp')) {
            New-Item -ItemType Directory -Path (Join-Path $ws $dirName) -Force | Out-Null
        }
        Initialize-PipelineRegistry -WorkspacePath $ws | Out-Null
        return $ws
    }

    function New-TestErrorRecord {
        param([string]$Message)

        try {
            throw [System.InvalidOperationException]::new($Message)
        } catch {
            return $_
        }
    }
}

Describe 'Add-ErrorToPipeline TEST-PEST naming' {
    It 'creates incrementing TEST-PEST Bugs2FIX IDs for simulated crashes' {
        $ws = New-ErrorLinkerWorkspace -Name 'ws-errorlinker-seq'

        $err1 = New-TestErrorRecord -Message 'Simulated crash #1'
        $err2 = New-TestErrorRecord -Message 'Simulated crash #2'

        $r1 = Add-ErrorToPipeline -Exception $err1 -FunctionName 'Invoke-SimulatedCrash' -WorkspacePath $ws -UseTestPesterNaming
        $r2 = Add-ErrorToPipeline -Exception $err2 -FunctionName 'Invoke-SimulatedCrash' -WorkspacePath $ws -UseTestPesterNaming

        $r1.Success | Should -BeTrue
        $r2.Success | Should -BeTrue
        $r1.Bugs2FixId | Should -Be 'TEST-PEST1'
        $r2.Bugs2FixId | Should -Be 'TEST-PEST2'

        $fixes = @(Get-PipelineItems -WorkspacePath $ws -Type 'Bugs2FIX')
        @($fixes | Where-Object { $_.id -eq 'TEST-PEST1' }).Count | Should -Be 1
        @($fixes | Where-Object { $_.id -eq 'TEST-PEST2' }).Count | Should -Be 1
    }

    It 'resets sequence to 1 when test ordinal store is corrupt' {
        $ws = New-ErrorLinkerWorkspace -Name 'ws-errorlinker-corrupt-seq'
        $seqPath = Join-Path $ws 'temp\test-pester-sequence.txt'
        Set-Content -LiteralPath $seqPath -Value 'corrupt-sequence' -Encoding UTF8 -Force

        $err = New-TestErrorRecord -Message 'Simulated crash after corrupt sequence'
        $r = Add-ErrorToPipeline -Exception $err -FunctionName 'Invoke-SimulatedCrash' -WorkspacePath $ws -UseTestPesterNaming

        $r.Success | Should -BeTrue
        $r.Bugs2FixId | Should -Be 'TEST-PEST1'
    }
}
