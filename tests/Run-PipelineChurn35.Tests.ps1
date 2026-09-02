# VersionTag: 2608.B1.V1.2
# SupportPS5.1: YES
# SupportsPS7.6: YES
#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:ChurnScript = Join-Path $script:RepoRoot 'scripts\Run-PipelineChurn35.ps1'
    $script:Source = Get-Content -LiteralPath $script:ChurnScript -Raw -Encoding UTF8
}

Describe 'Run-PipelineChurn35 operator controls' {
    It 'uses two cycles and validates batch input instead of retaining the old 35/25 defaults' {
        $script:Source | Should -Match '\[int\]\$MaxCycles = 2'
        $script:Source | Should -Match '\[int\]\$BatchSize = 7'
        $script:Source | Should -Match 'TimeoutSeconds 15'
        $script:Source | Should -Match 'DefaultValue 10'
    }

    It 'has a pre-mutation evolution alignment gate for CronAiAthon and VS Code tasks' {
        $script:Source | Should -Match 'Test-PipelineEvolutionAlignment'
        $script:Source | Should -Match 'CronAiAthon-Pipeline\.psm1'
        $script:Source | Should -Match 'CronAiAthon-Scheduler\.psm1'
        $script:Source | Should -Match 'Invoke-CronProcessor\.ps1'
        $script:Source | Should -Match '\.vscode\\tasks\.json'
        $script:Source | Should -Match 'evolution alignment gate failed'
    }

    It 'offers remaining-queue continuation with 30-second cycle and 7-second batch prompts' {
        $script:Source | Should -Match 'Todo queues remain'
        $script:Source | Should -Match 'DefaultValue \$MaxCycles -TimeoutSeconds 30'
        $script:Source | Should -Match 'DefaultValue \$BatchSize -TimeoutSeconds 7'
        $script:Source | Should -Match "Phase\s*=\s*'continuation'"
    }

    It 'supports unattended execution without blocking for console input' {
        $script:Source | Should -Match '\[switch\]\$NonInteractive'
        $script:Source | Should -Match '\$NonInteractive\.IsPresent'
    }

    It 'renders aligned queue fields and categorized batch commentary' {
        $script:Source | Should -Match 'function Write-QueueSnapshot'
        $script:Source | Should -Match 'PadRight\(\$width\)'
        $script:Source | Should -Match 'function Write-BatchProgress'
        $script:Source | Should -Match '\[Info\]-\[neverreallyaskedforbutitsgiven\]'
        $script:Source | Should -Match 'Category'
    }
}
