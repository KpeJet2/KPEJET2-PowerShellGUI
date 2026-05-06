# VersionTag: 2605.B2.V31.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
.SYNOPSIS  Pass 1 - TrayHost module Pester tests (IMPL-20260405-004).
.DESCRIPTION
    Tests for PwShGUI-TrayHost.psm1.
    Covers: Get-TrayHostStatus, Set-VerboseLifecycle, background pool
    create/task/stop cycle, Stop-TrayHost contract, keyboard monitor start/stop.
    WinForms / System.Windows.Forms not required for non-UI path tests.
    Requires Pester v5+.
#>

BeforeAll {
    $ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\PwShGUI-TrayHost.psm1'
    if (-not (Test-Path $ModulePath)) { throw "Module not found: $ModulePath" }
    Import-Module $ModulePath -Force
}

AfterAll {
    # Ensure pools are stopped before unloading
    Stop-BackgroundPool -ErrorAction SilentlyContinue
    Remove-Module 'PwShGUI-TrayHost' -ErrorAction SilentlyContinue
}

Describe 'Set-VerboseLifecycle / Get-TrayHostStatus' {
    It 'Set-VerboseLifecycle does not throw' {
        { Set-VerboseLifecycle -Enabled $false } | Should -Not -Throw
    }

    It 'Get-TrayHostStatus returns a status object' {
        $status = Get-TrayHostStatus
        $status | Should -Not -BeNullOrEmpty
    }

    It 'status object has a Running property' {
        $status = Get-TrayHostStatus
        $status.PSObject.Properties.Name -contains 'Running' | Should -BeTrue
    }
}

Describe 'Background pool lifecycle' {
    It 'Initialize-BackgroundPool does not throw' {
        { Initialize-BackgroundPool } | Should -Not -Throw
    }

    It 'Invoke-BackgroundTask returns a job-like object' {
        Initialize-BackgroundPool
        $job = Invoke-BackgroundTask -ScriptBlock { Start-Sleep -Milliseconds 10; 'done' }
        $job | Should -Not -BeNullOrEmpty
    }

    It 'Get-CompletedBackgroundTasks returns array' {
        Start-Sleep -Milliseconds 200
        $completed = Get-CompletedBackgroundTasks
        $completed | Should -BeOfType [System.Array]
    }

    It 'Stop-BackgroundPool does not throw' {
        { Stop-BackgroundPool } | Should -Not -Throw
    }
}

Describe 'Stop-TrayHost' {
    It 'Stop-TrayHost does not throw when no tray is running' {
        { Stop-TrayHost -Force } | Should -Not -Throw
    }
}

Describe 'Keyboard monitor start/stop' {
    It 'Start-KeyboardMonitor does not throw' {
        { Start-KeyboardMonitor } | Should -Not -Throw
    }

    It 'Stop-KeyboardMonitor does not throw' {
        { Stop-KeyboardMonitor } | Should -Not -Throw
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





