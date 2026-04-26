# VersionTag: 2604.B2.V31.2
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
    It 'Exports 15 functions' {
        $exports = (Get-Module 'CronAiAthon-Scheduler').ExportedFunctions.Keys
        $exports.Count | Should -Be 15
    }
}

Describe 'Get-CronSchedule' {
    It 'Returns schedule data without error' {
        { Get-CronSchedule } | Should -Not -Throw
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




