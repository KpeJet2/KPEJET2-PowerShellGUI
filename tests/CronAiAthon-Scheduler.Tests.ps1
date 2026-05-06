# VersionTag: 2605.B5.V45.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS  CronAiAthon-Scheduler module Pester tests.
.DESCRIPTION
    Tests for CronAiAthon-Scheduler.psm1: task scheduling, cron cycle orchestration,
    and timer-based job management.
    Requires Pester v5+.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\CronAiAthon-Scheduler.psm1'
    Import-Module $modulePath -Force
}

Describe 'CronAiAthon-Scheduler Module' {
    It 'Imports successfully' {
        Get-Module 'CronAiAthon-Scheduler' | Should -Not -BeNullOrEmpty
    }
    It 'Exports required scheduler functions' {
        $exports = (Get-Module 'CronAiAthon-Scheduler').ExportedFunctions.Keys
        @($exports).Count | Should -BeGreaterOrEqual 15
        foreach ($name in @(
            'Initialize-CronSchedule',
            'Get-CronSchedule',
            'Save-CronSchedule',
            'Invoke-CronJob',
            'Invoke-AllCronJobs',
            'Get-CronJobHistory',
            'Get-CronJobSummary',
            'Set-CronFrequency'
        )) {
            $exports | Should -Contain $name
        }
    }
}

Describe 'Get-CronSchedule' {
    It 'Returns schedule data without error' {
        $wsPath = Join-Path $TestDrive 'ws-scheduler'
        { Get-CronSchedule -WorkspacePath $wsPath } | Should -Not -Throw
        $schedule = Get-CronSchedule -WorkspacePath $wsPath
        $schedule | Should -Not -BeNullOrEmpty
        $schedule.meta.schema | Should -Be 'CronAiAthon-Schedule/1.0'
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





