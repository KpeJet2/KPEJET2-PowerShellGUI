# VersionTag: 2605.B5.V45.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS  CronAiAthon-EventLog module Pester tests.
.DESCRIPTION
    Tests for CronAiAthon-EventLog.psm1: structured logging, severity routing,
    log rotation, and event persistence.
    Requires Pester v5+.
#>
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\modules\CronAiAthon-EventLog.psm1'
    Import-Module $modulePath -Force
}

Describe 'CronAiAthon-EventLog Module' {
    It 'Imports successfully' {
        Get-Module 'CronAiAthon-EventLog' | Should -Not -BeNullOrEmpty
    }
    It 'Exports required core functions' {
        $exports = (Get-Module 'CronAiAthon-EventLog').ExportedFunctions.Keys
        @($exports).Count | Should -BeGreaterOrEqual 9
        foreach ($name in @(
            'Register-EventLogSources',
            'Test-EventLogSourceReady',
            'Write-CronEventLog',
            'Send-SyslogMessage',
            'Write-SyslogFile',
            'Write-CronLog',
            'Get-EventLogConfig',
            'Get-SyslogEntries',
            'ConvertTo-SyslogSeverity'
        )) {
            $exports | Should -Contain $name
        }
    }
}

Describe 'Write-CronLog' {
    It 'Writes log entry without error' {
        { Write-CronLog -Message 'Test entry' -Severity 'Informational' -WorkspacePath $TestDrive } | Should -Not -Throw
    }
}

Describe 'ConvertTo-SyslogSeverity' {
    It 'Maps Debug to Debug' {
        ConvertTo-SyslogSeverity -AppLevel 'Debug' | Should -Be 'Debug'
    }
    It 'Maps Info to Informational' {
        ConvertTo-SyslogSeverity -AppLevel 'Info' | Should -Be 'Informational'
    }
    It 'Maps Warning to Warning' {
        ConvertTo-SyslogSeverity -AppLevel 'Warning' | Should -Be 'Warning'
    }
    It 'Maps Error to Error' {
        ConvertTo-SyslogSeverity -AppLevel 'Error' | Should -Be 'Error'
    }
    It 'Maps Critical to Critical' {
        ConvertTo-SyslogSeverity -AppLevel 'Critical' | Should -Be 'Critical'
    }
    It 'Maps Audit to Notice' {
        ConvertTo-SyslogSeverity -AppLevel 'Audit' | Should -Be 'Notice'
    }
    It 'Rejects invalid levels' {
        { ConvertTo-SyslogSeverity -AppLevel 'Bogus' } | Should -Throw
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





