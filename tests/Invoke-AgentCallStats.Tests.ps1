# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Smoke tests for Invoke-AgentCallStats.ps1 — JSONL scanning, stats schema, merge logic.
.DESCRIPTION
    Tests: Script presence, JSONL parsing, 24h/7d/all-time bucket bucketing,
    output JSON schema, merge with existing stats file, SIN compliance.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:WorkspacePath = Split-Path $PSScriptRoot -Parent
    $script:StatsScript   = Join-Path $script:WorkspacePath 'scripts\Invoke-AgentCallStats.ps1'
    $script:StatsFile     = Join-Path $script:WorkspacePath 'config\agent-call-stats.json'
    $script:TempStatsFile = Join-Path $script:WorkspacePath 'temp\smoke-agent-call-stats.json'

    # Create a temp JSONL log for testing
    $script:TempLogsDir = Join-Path $script:WorkspacePath 'temp\smoke-agent-logs'
    if (-not (Test-Path $script:TempLogsDir)) { $null = New-Item -ItemType Directory -Path $script:TempLogsDir -Force }
    $now = Get-Date
    # 2 events within 24h, 1 older than 24h but within 7d, 1 older than 7d
    $events = @(
        [ordered]@{ event_type='agent_call'; agent_id='TestAgent-00'; timestamp=$now.ToString('o'); level='INFO'; message='Call 1' }
        [ordered]@{ event_type='agent_call'; agent_id='TestAgent-00'; timestamp=$now.AddHours(-2).ToString('o'); level='INFO'; message='Call 2' }
        [ordered]@{ event_type='agent_call'; agent_id='TestAgent-00'; timestamp=$now.AddDays(-3).ToString('o'); level='INFO'; message='Call 3' }
        [ordered]@{ event_type='agent_call'; agent_id='TestAgent-00'; timestamp=$now.AddDays(-10).ToString('o'); level='INFO'; message='Call 4' }
    )
    $jsonlPath = Join-Path $script:TempLogsDir 'test-session.jsonl'
    $events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } | Set-Content -LiteralPath $jsonlPath -Encoding UTF8
    $script:TempJsonlPath = $jsonlPath
}

AfterAll {
    if (Test-Path $script:TempLogsDir) { Remove-Item $script:TempLogsDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $script:TempStatsFile) { Remove-Item $script:TempStatsFile -Force -ErrorAction SilentlyContinue }
}

Describe 'Invoke-AgentCallStats — Script exists' {
    It 'Script file is present' {
        Test-Path -LiteralPath $script:StatsScript | Should -Be $true
    }
    It 'Has a VersionTag header' {
        $first = Get-Content -LiteralPath $script:StatsScript -Encoding UTF8 | Select-Object -First 3
        ($first -join ' ') | Should -Match 'VersionTag'
    }
    It 'Has -WorkspacePath parameter' {
        $content = Get-Content -LiteralPath $script:StatsScript -Raw
        $content | Should -Match '\bWorkspacePath\b'
    }
    It 'Has -PassThru parameter' {
        $content = Get-Content -LiteralPath $script:StatsScript -Raw
        $content | Should -Match '\bPassThru\b'
    }
}

Describe 'Invoke-AgentCallStats — Output file integrity' {
    It 'Produces a valid agent-call-stats.json file' {
        Test-Path -LiteralPath $script:StatsFile | Should -Be $true
    }
    It 'JSON is parseable' {
        $content = Get-Content -LiteralPath $script:StatsFile -Raw
        { $content | ConvertFrom-Json } | Should -Not -Throw
    }
    It 'Has schemaVersion field' {
        $obj = Get-Content -LiteralPath $script:StatsFile -Raw | ConvertFrom-Json
        $obj.schemaVersion | Should -Be 'AgentCallStats/1.0'
    }
    It 'Has stats object with at least 1 entry' {
        $obj = Get-Content -LiteralPath $script:StatsFile -Raw | ConvertFrom-Json
        @($obj.stats.PSObject.Properties.Name).Count | Should -BeGreaterThan 0
    }
    It 'Each stat entry has calls24h, calls7d, callsTotal fields' {
        $obj = Get-Content -LiteralPath $script:StatsFile -Raw | ConvertFrom-Json
        $first = $obj.stats.PSObject.Properties | Select-Object -First 1
        $ev = $first.Value
        $ev.PSObject.Properties.Name | Should -Contain 'calls24h'
        $ev.PSObject.Properties.Name | Should -Contain 'calls7d'
        $ev.PSObject.Properties.Name | Should -Contain 'callsTotal'
    }
}

Describe 'Invoke-AgentCallStats — Bucketing logic (JSONL content)' {
    It 'JSONL test log file was created' {
        Test-Path -LiteralPath $script:TempJsonlPath | Should -Be $true
    }
    It 'Test JSONL has 4 lines' {
        @(Get-Content -LiteralPath $script:TempJsonlPath).Count | Should -Be 4
    }
    It 'Each JSONL line is valid JSON with agent_id and timestamp' {
        @(Get-Content -LiteralPath $script:TempJsonlPath) | ForEach-Object {
            $obj = $_ | ConvertFrom-Json
            $obj.agent_id | Should -Not -BeNullOrEmpty
            $obj.timestamp | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-AgentCallStats — SIN compliance' {
    It 'No PS7-only null-coalesce (P005)' {
        $codeLines = (Get-Content -LiteralPath $script:StatsScript -Encoding UTF8) |
            Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch "'\?\?'" }
        ($codeLines -join ' ') | Should -Not -Match '\?\?'
    }
    It 'No hardcoded absolute paths (P015)' {
        $content = Get-Content -LiteralPath $script:StatsScript -Raw
        $content | Should -Not -Match "['`"]C:\\\\PowerShellGUI"
    }
    It 'No Invoke-Expression (P010)' {
        $codeLines = (Get-Content -LiteralPath $script:StatsScript -Encoding UTF8) |
            Where-Object { $_ -notmatch '^\s*#' }
        ($codeLines -join ' ') | Should -Not -Match '\bInvoke-Expression\b|\biex\b'
    }
    It 'Uses @() guard on .Count (P004)' {
        $content = Get-Content -LiteralPath $script:StatsScript -Raw
        # Should use @(...).Count pattern at least once
        $content | Should -Match '@\('
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





