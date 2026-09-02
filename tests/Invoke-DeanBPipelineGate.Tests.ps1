# VersionTag: 2608.B0.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
#Requires -Modules Pester

Describe 'DeanB pipeline gate wiring' {
    BeforeAll {
        $script:WorkspaceRoot = Split-Path -Parent $PSScriptRoot
        $script:IterationPath = Join-Path $script:WorkspaceRoot 'scripts\Invoke-InteropDriftIteration.ps1'
        $script:DeanBPath = Join-Path $script:WorkspaceRoot 'scripts\Invoke-DeanBPipelineGate.ps1'
        $script:MultiPassPath = Join-Path $script:WorkspaceRoot 'scripts\Invoke-PipelineMultiPass.ps1'
        $script:SolutionMapPath = Join-Path $script:WorkspaceRoot 'config\deanb-solution-map.json'
    }

    It 'declares DeanB and randomized SIN stages in the iteration runner' {
        $content = Get-Content -LiteralPath $script:IterationPath -Raw -Encoding UTF8
        $content | Should -Match 'Digital Effluence and nauance blender'
        $content | Should -Match 'Get-Random -Minimum 1 -Maximum 6'
        $content | Should -Match 'BatchSize 7'
        $content | Should -Match 'completion-audit'
    }

    It 'relays DeanB controls through the multi-pass runner' {
        $content = Get-Content -LiteralPath $script:MultiPassPath -Raw -Encoding UTF8
        $content | Should -Match '\$iterArgs\.NoDeanB'
        $content | Should -Match 'stageRelay'
        $content | Should -Match 'gateRelayPassed'
    }

    It 'defines a bounded DeanB batch contract' {
        $content = Get-Content -LiteralPath $script:DeanBPath -Raw -Encoding UTF8
        $content | Should -Match '\[ValidateRange\(1, 7\)\]'
        $content | Should -Match "-Type 'Bugs2FIX'"
        $content | Should -Match "-MaxAttempts 1"
    }

    It 'contains one unique solution entry for every outstanding finding' {
        $map = Get-Content -LiteralPath $script:SolutionMapPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $map.findingCount | Should -Be 154
        @($map.entries).Count | Should -Be 154
        @($map.entries.solutionId | Sort-Object -Unique).Count | Should -Be 154
        @($map.entries | Where-Object { $_.route -eq 'ManifestExportReview' }).Count | Should -Be 141
        @($map.entries | Where-Object { $_.route -eq 'LauncherPathReview' }).Count | Should -Be 13
    }
}