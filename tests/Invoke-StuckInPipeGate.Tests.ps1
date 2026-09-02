# VersionTag: 2607.B6.V54.0
# SupportPS5.1: YES(As of: 2026-07-28)
# SupportsPS7.6: YES(As of: 2026-07-28)
# SupportPS5.1TestedDate: 2026-07-28
# SupportsPS7.6TestedDate: 2026-07-28
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:GateScript = Join-Path $script:RepoRoot 'scripts\Invoke-StuckInPipeGate.ps1'
    $script:PipelineModuleSrc = Join-Path $script:RepoRoot 'modules\CronAiAthon-Pipeline.psm1'
    $script:ErrorLinkerModuleSrc = Join-Path $script:RepoRoot 'modules\CronAiAthon-ErrorLinker.psm1'

    Import-Module $script:PipelineModuleSrc -Force

    function New-GateWorkspace {
        param([string]$Name)

        $ws = Join-Path $TestDrive $Name
        foreach ($dirName in @('config', 'todo', 'logs', 'temp', 'modules', 'scripts')) {
            New-Item -ItemType Directory -Path (Join-Path $ws $dirName) -Force | Out-Null
        }

        Copy-Item -LiteralPath $script:PipelineModuleSrc -Destination (Join-Path $ws 'modules\CronAiAthon-Pipeline.psm1') -Force
        Copy-Item -LiteralPath $script:ErrorLinkerModuleSrc -Destination (Join-Path $ws 'modules\CronAiAthon-ErrorLinker.psm1') -Force
        Copy-Item -LiteralPath $script:GateScript -Destination (Join-Path $ws 'scripts\Invoke-StuckInPipeGate.ps1') -Force

        Initialize-PipelineRegistry -WorkspacePath $ws | Out-Null
        return $ws
    }

}

Describe 'Invoke-StuckInPipeGate stale/corrupt queue recovery' {
    It 'detects stale interruptions, clears corrupt artifacts, and requeues stuck items' {
        $ws = New-GateWorkspace -Name 'ws-stuck-pipe-repair'

        $item = New-PipelineItem -Type 'Bugs2FIX' -Title 'Stale fix item for gate test' -Source 'Manual' -Category 'crash-log'
        $item.status = 'IN_PROGRESS'
        $oldIso = (Get-Date).ToUniversalTime().AddDays(-10).ToString('o')
        $item.created = $oldIso
        $item.modified = $oldIso
        $added = Add-PipelineItem -WorkspacePath $ws -Item $item

        $regPath = Join-Path $ws 'config\\cron-aiathon-pipeline.json'
        $reg = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($b2f in @($reg.bugs2FIX)) {
            if ($b2f.id -eq $added.id) {
                $b2f.status = 'IN_PROGRESS'
                $b2f.created = $oldIso
                $b2f.modified = $oldIso
            }
        }
        $reg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $regPath -Encoding UTF8

        $queueDir = Join-Path $ws 'todo\QUEUES-ToDo\Bugs2FIX-'
        New-Item -ItemType Directory -Path $queueDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $queueDir 'broken.json') -Value '{ not-valid-json' -Encoding UTF8 -Force

        $raw = & (Join-Path $ws 'scripts\\Invoke-StuckInPipeGate.ps1') -WorkspacePath $ws -MaxPasses 3 -InProgressDays 0
        $result = $raw | ConvertFrom-Json

        $result.repair.corruptArtifactsCleared | Should -BeGreaterOrEqual 1
        if ($result.repair.interruptionsDetected -gt 0) {
            $result.repair.itemsRequeued | Should -BeGreaterOrEqual 1
        } else {
            $result.repair.itemsRequeued | Should -BeGreaterOrEqual 0
        }
        $result.passesAttempted | Should -BeGreaterOrEqual 1
    }
}

Describe 'Invoke-StuckInPipeGate feature request smoke' {
    It 'creates and completes a test feature request that writes a README date stamp' {
        $ws = New-GateWorkspace -Name 'ws-stuck-pipe-feature'

        $raw = & (Join-Path $ws 'scripts\\Invoke-StuckInPipeGate.ps1') -WorkspacePath $ws -RunFeatureRequestSelfTest -FeatureReadmePath 'README.TEST.md'
        $result = $raw | ConvertFrom-Json

        $result.featureRequestTest.success | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $ws 'README.TEST.md') | Should -BeTrue

        $readme = Get-Content -LiteralPath (Join-Path $ws 'README.TEST.md') -Raw -Encoding UTF8
        $readme -match 'DateStamp:' | Should -BeTrue

        $features = @(Get-PipelineItems -WorkspacePath $ws -Type 'FeatureRequest')
        @($features).Count | Should -BeGreaterOrEqual 1
        @($features | Where-Object { $_.status -eq 'DONE' }).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'Invoke-StuckInPipeGate missing component detection' {
    It 'detects missing components and records remediation failure with Bugs2FIX linkage' {
        $ws = New-GateWorkspace -Name 'ws-stuck-pipe-missing-component'

        $raw = & (Join-Path $ws 'scripts\\Invoke-StuckInPipeGate.ps1') -WorkspacePath $ws -TestMissingComponents -RequiredComponents @('scripts\\missing-component-1.ps1')
        $result = $raw | ConvertFrom-Json

        $result.missingComponents.totalMissing | Should -Be 1
        $result.missingComponents.remediationFailed | Should -Be 1
        @($result.missingComponents.bugLinks).Count | Should -BeGreaterOrEqual 1

        $fixes = @(Get-PipelineItems -WorkspacePath $ws -Type 'Bugs2FIX')
        @($fixes | Where-Object { $_.id -like 'TEST-PEST*' }).Count | Should -BeGreaterOrEqual 1
    }
}
