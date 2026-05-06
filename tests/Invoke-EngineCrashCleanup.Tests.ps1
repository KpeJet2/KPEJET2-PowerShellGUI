# VersionTag: 2604.B1.V32.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Smoke tests for Invoke-EngineCrashCleanup.ps1 — quarantine, report, and SIN compliance.
.DESCRIPTION
    Tests: Script presence, required parameters, quarantine directory creation,
    report output schema, SIN P001/P005/P010/P015 compliance.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:WorkspacePath  = Split-Path $PSScriptRoot -Parent
    $script:CleanupScript  = Join-Path $script:WorkspacePath 'scripts\Invoke-EngineCrashCleanup.ps1'
    $script:TempQuarantine = Join-Path $script:WorkspacePath 'temp\smoke-crash-quarantine'
}

AfterAll {
    if (Test-Path $script:TempQuarantine) {
        Remove-Item $script:TempQuarantine -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-EngineCrashCleanup — Script exists' {
    It 'Script file is present' {
        Test-Path -LiteralPath $script:CleanupScript | Should -Be $true
    }
    It 'Has a VersionTag header' {
        $first = Get-Content -LiteralPath $script:CleanupScript -Encoding UTF8 | Select-Object -First 3
        ($first -join ' ') | Should -Match 'VersionTag'
    }
    It 'Has param block with WorkspacePath' {
        $content = Get-Content -LiteralPath $script:CleanupScript -Raw
        $content | Should -Match '\bWorkspacePath\b'
    }
}

Describe 'Invoke-EngineCrashCleanup — Quarantine handling' {
    It 'Script references quarantine directory creation' {
        $content = Get-Content -LiteralPath $script:CleanupScript -Raw
        $content | Should -Match 'quarantine|Quarantine'
    }
    It 'Script writes a report or log for crash events' {
        $content = Get-Content -LiteralPath $script:CleanupScript -Raw
        $content | Should -Match 'report|Report|Write-AppLog|Write-CronLog'
    }
}

Describe 'Invoke-EngineCrashCleanup — SIN compliance' {
    It 'No hardcoded credentials (P001)' {
        $content = Get-Content -LiteralPath $script:CleanupScript -Raw
        $content | Should -Not -Match 'password\s*=|apikey\s*=|secret\s*=' -Because 'P001 no hardcoded creds'
    }
    It 'No PS7-only null-coalesce operator (P005)' {
        $codeLines = (Get-Content -LiteralPath $script:CleanupScript -Encoding UTF8) |
            Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch "'\?\?'" }
        ($codeLines -join ' ') | Should -Not -Match '\?\?'
    }
    It 'No Invoke-Expression (P010)' {
        $codeLines = (Get-Content -LiteralPath $script:CleanupScript -Encoding UTF8) |
            Where-Object { $_ -notmatch '^\s*#' }
        ($codeLines -join ' ') | Should -Not -Match '\bInvoke-Expression\b|\biex\b'
    }
    It 'No hardcoded absolute paths (P015)' {
        $content = Get-Content -LiteralPath $script:CleanupScript -Raw
        $content | Should -Not -Match "['`"]C:\\\\PowerShellGUI"
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




