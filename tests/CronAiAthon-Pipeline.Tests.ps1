# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Pester unit tests for CronAiAthon-Pipeline module -- Pass 3.
.DESCRIPTION
    Tests: New-PipelineItem, status transitions, outline schema, batch ops,
    health metrics, category taxonomy, bundle regeneration, sin guard.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\CronAiAthon-Pipeline.psm1'
    Import-Module $modulePath -Force
}

Describe 'New-PipelineItem' {
    It 'Should create an item with all required fields' {
        $item = New-PipelineItem -Type 'Bug' -Title 'Test Bug'
        $item.id | Should -BeLike 'Bug-*'
        $item.type | Should -Be 'Bug'
        $item.title | Should -Be 'Test Bug'
        $item.status | Should -Be 'OPEN'
        $item.priority | Should -Be 'MEDIUM'
        $item.sessionModCount | Should -Be 1
    }

    It 'Should include outline fields by default' {
        $item = New-PipelineItem -Type 'ToDo' -Title 'Outline Test'
        $item.outlineTag | Should -Be 'OUTLINE-PROTO-v0'
        $item.outlinePhase | Should -Be 'assessment'
        $item.outlineVersion | Should -Be 'v0'
    }

    It 'Should accept custom outline fields' {
        $item = New-PipelineItem -Type 'FeatureRequest' -Title 'Custom Outline' `
            -OutlinePhase 'review' -OutlineVersion 'v1'
        $item.outlinePhase | Should -Be 'review'
        $item.outlineVersion | Should -Be 'v1'
    }

    It 'Should accept all valid types' {
        foreach ($t in @('FeatureRequest','Bug','Items2ADD','Bugs2FIX','ToDo')) {
            $item = New-PipelineItem -Type $t -Title "Test $t"
            $item.type | Should -Be $t
        }
    }

    It 'Should generate unique IDs' {
        $item1 = New-PipelineItem -Type 'Bug' -Title 'Bug A'
        Start-Sleep -Milliseconds 10
        $item2 = New-PipelineItem -Type 'Bug' -Title 'Bug B'
        $item1.id | Should -Not -Be $item2.id
    }
}

Describe 'Test-StatusTransition' {
    It 'Should allow OPEN -> PLANNED' {
        Test-StatusTransition -CurrentStatus 'OPEN' -NewStatus 'PLANNED' | Should -Be $true
    }

    It 'Should allow OPEN -> IN_PROGRESS' {
        Test-StatusTransition -CurrentStatus 'OPEN' -NewStatus 'IN_PROGRESS' | Should -Be $true
    }

    It 'Should allow IN_PROGRESS -> DONE' {
        Test-StatusTransition -CurrentStatus 'IN_PROGRESS' -NewStatus 'DONE' | Should -Be $true
    }

    It 'Should allow IN_PROGRESS -> TESTING' {
        Test-StatusTransition -CurrentStatus 'IN_PROGRESS' -NewStatus 'TESTING' | Should -Be $true
    }

    It 'Should allow TESTING -> DONE' {
        Test-StatusTransition -CurrentStatus 'TESTING' -NewStatus 'DONE' | Should -Be $true
    }

    It 'Should deny OPEN -> DONE (skip states)' {
        Test-StatusTransition -CurrentStatus 'OPEN' -NewStatus 'DONE' | Should -Be $false
    }

    It 'Should deny TESTING -> PLANNED' {
        Test-StatusTransition -CurrentStatus 'TESTING' -NewStatus 'PLANNED' | Should -Be $false
    }

    It 'Should allow BLOCKED -> OPEN (re-open)' {
        Test-StatusTransition -CurrentStatus 'BLOCKED' -NewStatus 'OPEN' | Should -Be $true
    }

    It 'Should allow CLOSED -> OPEN (re-open)' {
        Test-StatusTransition -CurrentStatus 'CLOSED' -NewStatus 'OPEN' | Should -Be $true
    }
}

Describe 'Initialize-PipelineRegistry' {
    It 'Should create a registry file in TestDrive' {
        $wsPath = Join-Path $TestDrive 'ws-pipe'
        New-Item -ItemType Directory -Path (Join-Path $wsPath 'config') -Force | Out-Null
        $reg = Initialize-PipelineRegistry -WorkspacePath $wsPath
        $reg | Should -Not -BeNullOrEmpty
        $regFile = Join-Path $wsPath 'config\cron-aiathon-pipeline.json'
        Test-Path $regFile | Should -Be $true
    }

    It 'Should use schema version 1.1' {
        $wsPath = Join-Path $TestDrive 'ws-pipe2'
        New-Item -ItemType Directory -Path (Join-Path $wsPath 'config') -Force | Out-Null
        $reg = Initialize-PipelineRegistry -WorkspacePath $wsPath
        $reg.meta.schema | Should -Be 'CronAiAthon-Pipeline/1.1'
    }

    It 'Should include outlineSchema in meta' {
        $wsPath = Join-Path $TestDrive 'ws-pipe3'
        New-Item -ItemType Directory -Path (Join-Path $wsPath 'config') -Force | Out-Null
        $reg = Initialize-PipelineRegistry -WorkspacePath $wsPath
        $reg.meta.outlineSchema | Should -Be 'PwShGUI-Outline/0.1'
    }
}

Describe 'Pipeline CRUD' {
    BeforeAll {
        $script:wsPath = Join-Path $TestDrive 'ws-crud'
        New-Item -ItemType Directory -Path (Join-Path $script:wsPath 'config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:wsPath 'todo') -Force | Out-Null
        Initialize-PipelineRegistry -WorkspacePath $script:wsPath
    }

    It 'Should add an item to the registry' {
        $item = New-PipelineItem -Type 'Bug' -Title 'CRUD Test Bug'
        $added = Add-PipelineItem -WorkspacePath $script:wsPath -Item $item
        $added.id | Should -BeLike 'Bug-*'
    }

    It 'Should retrieve added items' {
        $items = Get-PipelineItems -WorkspacePath $script:wsPath
        $items.Count | Should -BeGreaterOrEqual 1
    }

    It 'Should update item status with valid transition' {
        $items = Get-PipelineItems -WorkspacePath $script:wsPath
        $id = $items[0].id
        $result = Update-PipelineItemStatus -WorkspacePath $script:wsPath -ItemId $id -NewStatus 'IN_PROGRESS'
        $result | Should -Be $true
    }

    It 'Should block invalid status transition without -Force' {
        $items = Get-PipelineItems -WorkspacePath $script:wsPath
        $id = $items[0].id
        # Item is now IN_PROGRESS, trying to go to PLANNED should fail
        $result = Update-PipelineItemStatus -WorkspacePath $script:wsPath -ItemId $id -NewStatus 'PLANNED' 3>$null
        $result | Should -Be $false
    }
}

Describe 'Get-ValidCategories' {
    It 'Should return a non-empty array' {
        $cats = Get-ValidCategories
        $cats.Count | Should -BeGreaterThan 10
    }

    It 'Should include core categories' {
        $cats = Get-ValidCategories
        $cats | Should -Contain 'error-handling'
        $cats | Should -Contain 'security'
        $cats | Should -Contain 'performance'
        $cats | Should -Contain 'testing'
    }
}

Describe 'Resolve-ItemCategory' {
    It 'Should map exact category' {
        Resolve-ItemCategory -RawCategory 'security' | Should -Be 'security'
    }

    It 'Should map partial match' {
        Resolve-ItemCategory -RawCategory 'parse error' | Should -Be 'parsing'
    }

    It 'Should map abbreviation' {
        Resolve-ItemCategory -RawCategory 'perf' | Should -Be 'performance'
    }

    It 'Should default to general for unknown' {
        Resolve-ItemCategory -RawCategory 'xyz-unknown-123' | Should -Be 'general'
    }

    It 'Should handle null/empty' {
        Resolve-ItemCategory -RawCategory '' | Should -Be 'general'
    }
}

Describe 'Get-PipelineHealthMetrics' {
    It 'Should return metrics object' {
        $wsPath = Join-Path $TestDrive 'ws-health'
        New-Item -ItemType Directory -Path (Join-Path $wsPath 'config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $wsPath 'todo') -Force | Out-Null
        Initialize-PipelineRegistry -WorkspacePath $wsPath

        $metrics = Get-PipelineHealthMetrics -WorkspacePath $wsPath
        $metrics | Should -Not -BeNullOrEmpty
        $metrics.totalItems | Should -BeOfType [int]
        $metrics.openItems | Should -BeOfType [int]
        $metrics.backlogAge | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-BugSinResolved' {
    It 'Should return true for empty SinId' {
        $wsPath = Join-Path $TestDrive 'ws-sin'
        Test-BugSinResolved -WorkspacePath $wsPath -SinId '' | Should -Be $true
    }

    It 'Should return true for non-existent sin file' {
        $wsPath = Join-Path $TestDrive 'ws-sin2'
        Test-BugSinResolved -WorkspacePath $wsPath -SinId 'SIN-nonexistent' | Should -Be $true
    }

    It 'Should return false for unresolved sin' {
        $wsPath = Join-Path $TestDrive 'ws-sin3'
        $sinDir = Join-Path $wsPath 'sin_registry'
        New-Item -ItemType Directory -Path $sinDir -Force | Out-Null
        $sin = @{ sin_id = 'SIN-test'; is_resolved = $false } | ConvertTo-Json -Depth 5
        Set-Content -Path (Join-Path $sinDir 'SIN-test.json') -Value $sin -Encoding UTF8
        Test-BugSinResolved -WorkspacePath $wsPath -SinId 'SIN-test' | Should -Be $false
    }

    It 'Should return true for resolved sin' {
        $wsPath = Join-Path $TestDrive 'ws-sin4'
        $sinDir = Join-Path $wsPath 'sin_registry'
        New-Item -ItemType Directory -Path $sinDir -Force | Out-Null
        $sin = @{ sin_id = 'SIN-resolved'; is_resolved = $true } | ConvertTo-Json -Depth 5
        Set-Content -Path (Join-Path $sinDir 'SIN-resolved.json') -Value $sin -Encoding UTF8
        Test-BugSinResolved -WorkspacePath $wsPath -SinId 'SIN-resolved' | Should -Be $true
    }
}

Describe 'Update-TodoBundle' {
    It 'Should regenerate _bundle.js from todo JSON files' {
        $wsPath = Join-Path $TestDrive 'ws-bundle'
        $todoDir = Join-Path $wsPath 'todo'
        New-Item -ItemType Directory -Path $todoDir -Force | Out-Null

        # Create a test todo JSON
        $testItem = @{ todo_id = 'test-001'; title = 'Bundle Test'; status = 'OPEN' } | ConvertTo-Json -Depth 5
        Set-Content -Path (Join-Path $todoDir 'test-001.json') -Value $testItem -Encoding UTF8

        $result = Update-TodoBundle -WorkspacePath $wsPath
        $result | Should -Not -BeNullOrEmpty
        Test-Path $result | Should -Be $true

        $content = Get-Content $result -Raw
        $content | Should -BeLike '*_todoBundle*'
        $content | Should -BeLike '*Bundle Test*'
    }
}

Describe 'Canonical Normalization' {
    It 'Should normalize legacy status aliases to canonical values' {
        ConvertTo-PipelineStatus -Status 'in-progress' | Should -Be 'IN_PROGRESS'
        ConvertTo-PipelineStatus -Status 'implemented' | Should -Be 'DONE'
        ConvertTo-PipelineStatus -Status 'deferred' | Should -Be 'CLOSED'
    }

    It 'Should normalize legacy type aliases to canonical values' {
        ConvertTo-PipelineItemType -Type 'feature' | Should -Be 'FeatureRequest'
        ConvertTo-PipelineItemType -Type 'todo' | Should -Be 'ToDo'
        ConvertTo-PipelineItemType -Type 'bug' | Should -Be 'Bug'
    }
}

Describe 'Artifact Integrity Parity' {
    It 'Should report healthy integrity after canonical refresh' {
        $wsPath = Join-Path $TestDrive 'ws-integrity'
        New-Item -ItemType Directory -Path (Join-Path $wsPath 'config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $wsPath 'todo') -Force | Out-Null
        Initialize-PipelineRegistry -WorkspacePath $wsPath | Out-Null

        $itemA = New-PipelineItem -Type 'Bug' -Title 'Integrity bug sample'
        $itemB = New-PipelineItem -Type 'ToDo' -Title 'Integrity todo sample'
        Add-PipelineItem -WorkspacePath $wsPath -Item $itemA | Out-Null
        Add-PipelineItem -WorkspacePath $wsPath -Item $itemB | Out-Null

        Invoke-PipelineArtifactRefresh -WorkspacePath $wsPath | Out-Null
        $integrity = Test-PipelineArtifactIntegrity -WorkspacePath $wsPath

        $integrity.isHealthy | Should -Be $true
        $integrity.checks.indexCountMatchesMaster | Should -Be $true
        $integrity.checks.indexFileCountMatchesActive | Should -Be $true
        $integrity.checks.bundleCountMatchesActive | Should -Be $true
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




