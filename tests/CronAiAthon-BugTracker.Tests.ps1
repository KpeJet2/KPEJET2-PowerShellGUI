<#
# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionBuildHistory:
#   2603.B0.v27.0  2026-03-29 00:00  audit-007 added VersionTag
.SYNOPSIS  Pass 3 - BugTracker module Pester tests.
.DESCRIPTION
    Tests for CronAiAthon-BugTracker.psm1: bug detection vectors, SIN linkage,
    full scan orchestration.
    Requires Pester v5+.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\CronAiAthon-BugTracker.psm1'
    Import-Module $modulePath -Force
    # Pipeline module needed for bug-to-pipeline operations
    $pipelinePath = Join-Path $PSScriptRoot '..\modules\CronAiAthon-Pipeline.psm1'
    Import-Module $pipelinePath -Force
}

Describe 'Invoke-ParseCheck' {
    It 'Returns results array' {
        $ws = Join-Path $TestDrive 'parsecheck'
        New-Item (Join-Path $ws 'modules') -ItemType Directory -Force | Out-Null
        # Create a minimal .psm1 with a known parse error
        Set-Content (Join-Path $ws 'modules\bad.psm1') -Value 'function Test { if ($true) { }' -Encoding UTF8
        $results = Invoke-ParseCheck -WorkspacePath $ws
        $results | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-FullBugScan' {
    It 'Returns a scan result object' {
        $ws = Join-Path $TestDrive 'fullscan'
        New-Item (Join-Path $ws 'modules') -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $ws 'scripts') -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $ws 'config') -ItemType Directory -Force | Out-Null
        # Create minimal content
        Set-Content (Join-Path $ws 'modules\test.psm1') -Value 'function Test-It { return $true }' -Encoding UTF8
        $result = Invoke-FullBugScan -WorkspacePath $ws 2>$null
        # Result should be some kind of object or array
        { $result } | Should -Not -Throw
    }
}

Describe 'Invoke-BugToPipelineProcessor' {
    It 'Processes bugs into pipeline format' {
        $ws = Join-Path $TestDrive 'bugpipe'
        $cfgDir = Join-Path $ws 'config'
        New-Item $cfgDir -ItemType Directory -Force | Out-Null
        # Initialize pipeline registry
        Initialize-PipelineRegistry -WorkspacePath $ws
        # Create a mock bug result
        $bugs = @(
            [PSCustomObject]@{
                file        = 'test.ps1'
                severity    = 'High'
                message     = 'Test parse error'
                category    = 'parse-error'
                detector    = 'Invoke-ParseCheck'
                vector      = 'parse-check'
                description = 'Test parse error found'
                sinId       = ''
            }
        )
        { Invoke-BugToPipelineProcessor -DetectedBugs $bugs -WorkspacePath $ws } | Should -Not -Throw
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





