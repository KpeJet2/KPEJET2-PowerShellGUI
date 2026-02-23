# VersionTag: 2604.B2.V31.0
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
    It 'Exports 9 functions' {
        $exports = (Get-Module 'CronAiAthon-EventLog').ExportedFunctions.Keys
        $exports.Count | Should -Be 9
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

