# VersionTag: 2608.B0.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
#Requires -Modules Pester

Describe 'TheGateBouncer and issue inventory' {
    BeforeAll {
        $script:WorkspaceRoot = Split-Path -Parent $PSScriptRoot
        $script:BouncerPath = Join-Path $script:WorkspaceRoot 'scripts\Invoke-TheGateBouncer.ps1'
        $script:InventoryPath = Join-Path $script:WorkspaceRoot 'scripts\Invoke-PipelineIssueInventory.ps1'
        $script:IterationPath = Join-Path $script:WorkspaceRoot 'scripts\Invoke-InteropDriftIteration.ps1'
    }

    It 'allows a configured bounded route with a relaxed-validation notice' {
        $result = & $script:BouncerPath -WorkspacePath $script:WorkspaceRoot -TargetPath 'scripts/Invoke-InteropDriftIteration.ps1' -Phase PreRemediation -AllowDetour
        $result.detourAllowed | Should -BeTrue
        $result.validationMode | Should -Be 'RELAXED_WITH_NOTICE'
        $result.relaxedValidationNotice | Should -BeTrue
        $result.protectedPath | Should -BeFalse
    }

    It 'blocks protected kernel paths even when detours are requested' {
        $result = & $script:BouncerPath -WorkspacePath $script:WorkspaceRoot -TargetPath 'sovereign-kernel/core/AgentRegistry.psm1' -Phase PostRemediation -AllowDetour
        $result.detourAllowed | Should -BeFalse
        $result.reason | Should -Be 'PROTECTED_PATH_KERNEL_OR_CACHE'
    }

    It 'wires inventory and pre/post bouncer stages into iteration reports' {
        $content = Get-Content -LiteralPath $script:IterationPath -Raw -Encoding UTF8
        $content | Should -Match 'Invoke-IssueInventory'
        $content | Should -Match 'TheGateBouncer-pre'
        $content | Should -Match 'TheGateBouncer-post'
        (Test-Path -LiteralPath $script:InventoryPath) | Should -BeTrue
    }
}
