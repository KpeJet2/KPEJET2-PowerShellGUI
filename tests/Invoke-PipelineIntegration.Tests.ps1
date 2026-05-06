# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Pester integration tests for the CronAiAthon pipeline -- Pass 4.
.DESCRIPTION
    End-to-end: create item -> transition -> close -> verify action-log.
    Validates bundle regeneration after item changes.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\CronAiAthon-Pipeline.psm1'
    Import-Module $modulePath -Force
}

Describe 'Pipeline End-to-End Lifecycle' {
    BeforeAll {
        $script:wsPath = Join-Path $TestDrive 'ws-integration'
        New-Item -ItemType Directory -Path (Join-Path $script:wsPath 'config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:wsPath 'todo') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:wsPath 'sin_registry') -Force | Out-Null
        Initialize-PipelineRegistry -WorkspacePath $script:wsPath
    }

    It 'Step 1: Create a ToDo item' {
        $script:todoItem = New-PipelineItem -Type 'ToDo' -Title 'Integration Test Todo' `
            -Description 'E2E lifecycle test' -Priority 'HIGH' -Category 'testing'
        $script:todoItem.id | Should -BeLike 'ToDo-*'
        $script:todoItem.outlineVersion | Should -Be 'v0'
        Add-PipelineItem -WorkspacePath $script:wsPath -Item $script:todoItem
    }

    It 'Step 2: Create a Bug item' {
        $script:bugItem = New-PipelineItem -Type 'Bug' -Title 'Integration Test Bug' `
            -Description 'E2E bug lifecycle' -Priority 'CRITICAL' -Category 'error-handling'
        Add-PipelineItem -WorkspacePath $script:wsPath -Item $script:bugItem
    }

    It 'Step 3: Verify items in registry' {
        $items = Get-PipelineItems -WorkspacePath $script:wsPath
        $items.Count | Should -Be 2
    }

    It 'Step 4: Transition ToDo OPEN -> IN_PROGRESS' {
        $result = Update-PipelineItemStatus -WorkspacePath $script:wsPath `
            -ItemId $script:todoItem.id -NewStatus 'IN_PROGRESS'
        $result | Should -Be $true
    }

    It 'Step 5: Transition ToDo IN_PROGRESS -> TESTING' {
        $result = Update-PipelineItemStatus -WorkspacePath $script:wsPath `
            -ItemId $script:todoItem.id -NewStatus 'TESTING'
        $result | Should -Be $true
    }

    It 'Step 6: Transition ToDo TESTING -> DONE' {
        $result = Update-PipelineItemStatus -WorkspacePath $script:wsPath `
            -ItemId $script:todoItem.id -NewStatus 'DONE' -Notes 'Integration test passed'
        $result | Should -Be $true
    }

    It 'Step 7: Verify item has completedAt timestamp' {
        $items = Get-PipelineItems -WorkspacePath $script:wsPath -Status 'DONE'
        $items.Count | Should -Be 1
        $items[0].completedAt | Should -Not -BeNullOrEmpty
    }

    It 'Step 8: Health metrics reflect changes' {
        $metrics = Get-PipelineHealthMetrics -WorkspacePath $script:wsPath
        $metrics.totalItems | Should -Be 2
        $metrics.closedItems | Should -Be 1
        $metrics.openItems | Should -Be 1
    }

    It 'Step 9: Bundle regeneration after changes' {
        $bundlePath = Update-TodoBundle -WorkspacePath $script:wsPath
        Test-Path $bundlePath | Should -Be $true
    }

    It 'Step 10: Statistics reflect completion' {
        $stats = Get-PipelineStatistics -WorkspacePath $script:wsPath
        $stats.totalItemsDone | Should -BeGreaterOrEqual 1
    }
}

Describe 'Batch Operations' {
    BeforeAll {
        $script:wsPath = Join-Path $TestDrive 'ws-batch'
        New-Item -ItemType Directory -Path (Join-Path $script:wsPath 'config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:wsPath 'todo') -Force | Out-Null
        Initialize-PipelineRegistry -WorkspacePath $script:wsPath

        # Create 5 bugs
        for ($i = 1; $i -le 5; $i++) {
            $item = New-PipelineItem -Type 'Bug' -Title "Batch Bug $i" -Category 'testing'
            Add-PipelineItem -WorkspacePath $script:wsPath -Item $item
        }
    }

    It 'Should batch-transition all OPEN bugs to PLANNED' {
        $changed = Set-PipelineItemBatchStatus -WorkspacePath $script:wsPath `
            -NewStatus 'PLANNED' -FilterType 'Bug' -FilterStatus 'OPEN'
        $changed | Should -Be 5
    }

    It 'Should filter by category' {
        # Add a non-testing bug
        $item = New-PipelineItem -Type 'Bug' -Title 'Security Bug' -Category 'security'
        Add-PipelineItem -WorkspacePath $script:wsPath -Item $item

        $changed = Set-PipelineItemBatchStatus -WorkspacePath $script:wsPath `
            -NewStatus 'IN_PROGRESS' -FilterCategory 'testing' -Force
        $changed | Should -Be 5
    }
}

Describe 'Outline Schema Operations' {
    BeforeAll {
        $script:wsPath = Join-Path $TestDrive 'ws-outline'
        New-Item -ItemType Directory -Path (Join-Path $script:wsPath 'config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:wsPath 'todo') -Force | Out-Null
        Initialize-PipelineRegistry -WorkspacePath $script:wsPath

        # Create items
        for ($i = 1; $i -le 3; $i++) {
            $item = New-PipelineItem -Type 'ToDo' -Title "Outline Test $i"
            Add-PipelineItem -WorkspacePath $script:wsPath -Item $item
        }
    }

    It 'Should set outline phase for all items' {
        $changed = Set-OutlinePhase -WorkspacePath $script:wsPath -Phase 'review'
        $changed | Should -Be 3
    }

    It 'Should confirm outline version from v0 to v1' {
        # Reset to v0 first
        Set-OutlinePhase -WorkspacePath $script:wsPath -Phase 'assessment'
        $confirmed = Confirm-OutlineVersion -WorkspacePath $script:wsPath
        $confirmed | Should -Be 3

        $items = Get-PipelineItems -WorkspacePath $script:wsPath
        foreach ($item in $items) {
            $item.outlineVersion | Should -Be 'v1'
            $item.outlinePhase | Should -Be 'accepted'
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




