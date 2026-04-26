# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Loadability tests for all Show-*.ps1 scripts.
.DESCRIPTION
    Parameterised Pester suite that checks every Show-*.ps1 script for:
      - File presence
      - VersionTag header
      - AST parse with zero errors
      - No PS7-only operators (SIN P005)
      - Safe dot-source (no GUI launched — all Show- scripts gate UI behind function calls)
    Note: Show-CronAiAthonTool.Tests.ps1 has deeper function-presence assertions.
    This suite covers the remaining 7 Show- scripts plus CronAiAthon as a baseline pass.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:WsPath = Split-Path $PSScriptRoot -Parent
}

$showScripts = @(
    'Show-AppTemplateManager',
    'Show-CertificateManager',
    'Show-EventLogViewer',
    'Show-MCPServiceConfig',
    'Show-SandboxTestTool',
    'Show-ScanDashboard',
    'Show-WorkspaceIntentReview'
)

Describe "Show-Script loadability — <_>" -ForEach $showScripts {
    BeforeAll {
        $script:ScriptName = $_
        $script:ScriptPath = Join-Path $script:WsPath "scripts\$script:ScriptName.ps1"
        $script:Content    = if (Test-Path -LiteralPath $script:ScriptPath) {
            Get-Content -LiteralPath $script:ScriptPath -Raw -Encoding UTF8
        } else { $null }
        $script:Lines      = if ($script:Content) {
            @($script:Content -split "`n")
        } else { @() }
    }

    It 'Script file exists' {
        Test-Path -LiteralPath $script:ScriptPath | Should -Be $true
    }

    It 'First line contains VersionTag' {
        $script:Lines[0].Trim() | Should -Match 'VersionTag'
    }

    It 'Parses with zero AST errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$errors
        ) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It 'Contains no PS7-only null-coalescing operator ??' {
        if ($null -eq $script:Content) { Set-ItResult -Pending -Because 'File missing'; return }
        $script:Content | Should -Not -Match '(?<!\?)\?\?(?!\?)' -Because 'SIN P005'
    }

    It 'Contains no PS7-only null-conditional accessor ?.' {
        if ($null -eq $script:Content) { Set-ItResult -Pending -Because 'File missing'; return }
        $script:Content | Should -Not -Match '\?\.' -Because 'SIN P005'
    }

    It 'Dot-sources without terminating error' {
        if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
            Set-ItResult -Pending -Because 'Script not found'
            return
        }
        { . $script:ScriptPath } | Should -Not -Throw
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




