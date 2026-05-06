# VersionTag: 2605.B5.V45.0
# SupportPS5.1: YES
# SupportsPS7.6: YES
# SupportPS5.1TestedDate: 2026-05-07
# SupportsPS7.6TestedDate: 2026-05-07
#Requires -Modules Pester
<#
.SYNOPSIS
    Integration tests for FeatureRequest churn and auto-approval pipeline scripts.
.DESCRIPTION
    Validates:
    - Feature -> TODO-PA decomposition path
    - Bug OPEN -> IN-PROGRESS transition path
    - Auto-approval promotion path for aged PENDING_APPROVAL items
    - Canonical event-log emission contains eventId/itemId/agentId/editor attribution
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Process20Script = Join-Path $script:RepoRoot 'scripts\Invoke-PipelineProcess20.ps1'
    $script:AutoApprovalScript = Join-Path $script:RepoRoot 'scripts\Invoke-AutoApprovalWriter.ps1'
    $script:AdapterModule = Join-Path $script:RepoRoot 'modules\PwShGUI-EventLogAdapter.psm1'
    $script:PwshPath = $null
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { $script:PwshPath = $pwsh.Source }

    function New-ChurnWorkspace {
        param([string]$Name)

        $ws = Join-Path $TestDrive $Name
        foreach ($dirName in @('config','todo','sin_registry','logs','modules')) {
            New-Item -ItemType Directory -Path (Join-Path $ws $dirName) -Force | Out-Null
        }

        if (Test-Path -LiteralPath $script:AdapterModule) {
            Copy-Item -LiteralPath $script:AdapterModule -Destination (Join-Path $ws 'modules\PwShGUI-EventLogAdapter.psm1') -Force
        }

        return $ws
    }

    function Write-TestJson {
        param(
            [Parameter(Mandatory)] [string]$Path,
            [Parameter(Mandatory)] [object]$Object
        )

        $Object | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
    }

    function Read-JsonFile {
        param([Parameter(Mandatory)] [string]$Path)
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }

    function Read-Jsonl {
        param([Parameter(Mandatory)] [string]$Path)
        $rows = @()
        foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $rows += ($line | ConvertFrom-Json) } catch { }
        }
        return @($rows)
    }
}

Describe 'Invoke-PipelineProcess20 churn lifecycle' {
    It 'decomposes feature into TODO-PA items and moves OPEN bugs to IN-PROGRESS' {
        $ws = New-ChurnWorkspace -Name 'ws-pipe20'
        $todoDir = Join-Path $ws 'todo'
        $nowIso = (Get-Date).ToUniversalTime().ToString('o')

        # Seed bugs (two OPEN and one DONE)
        Write-TestJson -Path (Join-Path $todoDir 'BUG-TEST-001.json') -Object ([ordered]@{
            id = 'BUG-TEST-001'; title = 'Pipeline bug A'; status = 'OPEN'; priority = 'HIGH'; created = $nowIso; modified = $nowIso
        })
        Write-TestJson -Path (Join-Path $todoDir 'BUG-TEST-002.json') -Object ([ordered]@{
            id = 'BUG-TEST-002'; title = 'Pipeline bug B'; status = 'OPEN'; priority = 'MEDIUM'; created = $nowIso; modified = $nowIso
        })
        Write-TestJson -Path (Join-Path $todoDir 'BUG-TEST-003.json') -Object ([ordered]@{
            id = 'BUG-TEST-003'; title = 'Pipeline bug C'; status = 'DONE'; priority = 'LOW'; created = $nowIso; modified = $nowIso
        })

        # Seed one feature for decomposition
        Write-TestJson -Path (Join-Path $todoDir 'FEATURE-TEST-001.json') -Object ([ordered]@{
            id = 'feature-F001'; title = 'Secrets Management'; status = 'OPEN'; priority = 'HIGH'; created = $nowIso; modified = $nowIso
        })

        $resultRaw = & $script:Process20Script -WorkspacePath $ws -BugCount 2 -Agent 'PesterAgent'
        $result = $resultRaw | ConvertFrom-Json

        $result.bugsMovedToInProgress | Should -Be 2
        $result.featureItemsCreated | Should -Be 7
        Test-Path -LiteralPath $result.log | Should -BeTrue

        $todoPaFiles = @(Get-ChildItem -LiteralPath $todoDir -Filter 'TODO-PA-*.json' -File)
        @($todoPaFiles).Count | Should -Be 7

        $sampleTodo = Read-JsonFile -Path $todoPaFiles[0].FullName
        $sampleTodo.status | Should -Be 'PENDING_APPROVAL'
        $sampleTodo.source_id | Should -Be 'feature-F001'
        @($sampleTodo.status_history).Count | Should -BeGreaterOrEqual 1
        $sampleTodo.status_history[0].by | Should -Be 'PesterAgent'

        $feature = Read-JsonFile -Path (Join-Path $todoDir 'FEATURE-TEST-001.json')
        $feature.status | Should -Be 'IN-PROGRESS'

        $bugFiles = @(Get-ChildItem -LiteralPath $todoDir -Filter 'BUG-TEST-*.json' -File)
        $inProgressCount = 0
        foreach ($bugFile in $bugFiles) {
            $bug = Read-JsonFile -Path $bugFile.FullName
            if ($bug.status -eq 'IN-PROGRESS') { $inProgressCount++ }
        }
        $inProgressCount | Should -Be 2
    }

    It 'writes canonical event rows including eventId, itemId, agentId, and editor' {
        $ws = New-ChurnWorkspace -Name 'ws-pipe20-events'
        $todoDir = Join-Path $ws 'todo'
        $nowIso = (Get-Date).ToUniversalTime().ToString('o')

        Write-TestJson -Path (Join-Path $todoDir 'BUG-EVT-001.json') -Object ([ordered]@{
            id = 'BUG-EVT-001'; title = 'Event bug'; status = 'OPEN'; priority = 'HIGH'; created = $nowIso; modified = $nowIso
        })
        Write-TestJson -Path (Join-Path $todoDir 'FEATURE-EVT-001.json') -Object ([ordered]@{
            id = 'feature-EVT-001'; title = 'Event feature'; status = 'OPEN'; priority = 'HIGH'; created = $nowIso; modified = $nowIso
        })

        & $script:Process20Script -WorkspacePath $ws -BugCount 1 -Agent 'PesterAgent' | Out-Null

        $eventFile = Join-Path $ws (Join-Path 'logs\eventlog-normalized' ('pipeline-' + (Get-Date -Format 'yyyyMMdd') + '.jsonl'))
        Test-Path -LiteralPath $eventFile | Should -BeTrue

        $rows = Read-Jsonl -Path $eventFile
        @($rows).Count | Should -BeGreaterOrEqual 1

        @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'eventId' -and $_.eventId }).Count | Should -BeGreaterOrEqual 1
        @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'itemId' -and $_.itemId }).Count | Should -BeGreaterOrEqual 1
        @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'agentId' -and $_.agentId -eq 'PesterAgent' }).Count | Should -BeGreaterOrEqual 1
        @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'editor' -and -not [string]::IsNullOrWhiteSpace([string]$_.editor) }).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'Invoke-AutoApprovalWriter lifecycle' {
    It 'promotes aged PENDING_APPROVAL items and emits attributed normalized events' {
        if (-not $script:PwshPath) {
            Set-ItResult -Skipped -Because 'pwsh executable not found'
            return
        }

        $ws = New-ChurnWorkspace -Name 'ws-auto-approval'
        $todoDir = Join-Path $ws 'todo'
        $oldIso = (Get-Date).ToUniversalTime().AddDays(-10).ToString('o')
        $newIso = (Get-Date).ToUniversalTime().AddDays(-1).ToString('o')

        Write-TestJson -Path (Join-Path $todoDir 'TODO-OLD-001.json') -Object ([ordered]@{
            id = 'TODO-OLD-001'; title = 'Old pending'; status = 'PENDING_APPROVAL';
            priority = 'HIGH'; created = $oldIso; createdAt = $oldIso; modified = $oldIso; plannedAt = $oldIso;
            status_history = @([ordered]@{ status = 'PENDING_APPROVAL'; by = 'Seeder'; timestamp = $oldIso })
        })

        Write-TestJson -Path (Join-Path $todoDir 'TODO-NEW-001.json') -Object ([ordered]@{
            id = 'TODO-NEW-001'; title = 'New pending'; status = 'PENDING_APPROVAL';
            priority = 'MEDIUM'; created = $newIso; createdAt = $newIso; modified = $newIso; plannedAt = $newIso;
            status_history = @([ordered]@{ status = 'PENDING_APPROVAL'; by = 'Seeder'; timestamp = $newIso })
        })

        & $script:PwshPath -NoProfile -ExecutionPolicy Bypass -File $script:AutoApprovalScript -WorkspacePath $ws -AgeDays 7 -MaxPerRun 10 | Out-Null
        $LASTEXITCODE | Should -Be 0

        $oldItem = Read-JsonFile -Path (Join-Path $todoDir 'TODO-OLD-001.json')
        $newItem = Read-JsonFile -Path (Join-Path $todoDir 'TODO-NEW-001.json')

        $oldItem.status | Should -Be 'AUTO_APPROVED'
        @($oldItem.status_history).Count | Should -BeGreaterOrEqual 2
        @($oldItem.status_history | Where-Object { $_.status -eq 'AUTO_APPROVED' -and $_.by -eq 'auto-approval-writer' }).Count | Should -Be 1
        $oldItem.PSObject.Properties.Name | Should -Contain 'autoApprovedAt'

        $newItem.status | Should -Be 'PENDING_APPROVAL'

        $eventFile = Join-Path $ws (Join-Path 'logs\eventlog-normalized' ('pipeline-' + (Get-Date -Format 'yyyyMMdd') + '.jsonl'))
        Test-Path -LiteralPath $eventFile | Should -BeTrue

        $rows = Read-Jsonl -Path $eventFile
        @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'itemId' -and $_.itemId -eq 'TODO-OLD-001' }).Count | Should -BeGreaterOrEqual 1
        @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'agentId' -and $_.agentId -eq 'auto-approval-writer' }).Count | Should -BeGreaterOrEqual 1
        @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'editor' -and -not [string]::IsNullOrWhiteSpace([string]$_.editor) }).Count | Should -BeGreaterOrEqual 1
        @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'eventId' -and $_.eventId }).Count | Should -BeGreaterOrEqual 1
    }
}

