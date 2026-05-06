# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Loadability tests for Show-CronAiAthonTool.ps1 — parse, import, function presence.
.DESCRIPTION
    Verifies: VersionTag, AST parse with 0 errors, safe dot-source (no GUI launched),
    primary function defined, nested helper functions present in source (static analysis),
    no P005 PS7-only operators.
    The WinForms form body is inside Show-CronAiAthonTool {} so dot-source does NOT open UI.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:WsPath     = Split-Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path $script:WsPath 'scripts\Show-CronAiAthonTool.ps1'
    $script:Content    = Get-Content -LiteralPath $script:ScriptPath -Raw -Encoding UTF8
    $script:Lines      = @(Get-Content -LiteralPath $script:ScriptPath -Encoding UTF8)
}

Describe 'Show-CronAiAthonTool — File presence and metadata' {
    It 'Script file exists' {
        Test-Path -LiteralPath $script:ScriptPath | Should -Be $true
    }
    It 'First line contains VersionTag' {
        $script:Lines[0] | Should -Match 'VersionTag'
    }
    It 'VersionTag matches canonical format YYMM.Bx.Vx.x' {
        $script:Lines[0] | Should -Match '\d{4}\.B\d+\.V\d+\.\d+'
    }
}

Describe 'Show-CronAiAthonTool — AST parse' {
    It 'Parses with zero errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$errors
        ) | Out-Null
        @($errors).Count | Should -Be 0 -Because 'No syntax errors should exist in the script'
    }
}

Describe 'Show-CronAiAthonTool — SIN P005: No PS7-only operators' {
    It 'Source contains no null-coalescing operator ??' {  # SIN-EXEMPT: P005 - false positive: regex/glob literal, not PS7 operator
        $script:Content | Should -Not -Match '(?<!\?)\?\?(?!\?)' -Because 'P005: ?? not valid in PS 5.1'  # SIN-EXEMPT: P005 - false positive: regex/glob literal, not PS7 operator
    }
    It 'Source contains no null-conditional member access ?.' {  # SIN-EXEMPT: P005 - false positive: regex/glob literal, not PS7 operator
        $script:Content | Should -Not -Match '\?\.' -Because 'P005: ?. not valid in PS 5.1'  # SIN-EXEMPT: P005 - false positive: regex/glob literal, not PS7 operator
    }
}

Describe 'Show-CronAiAthonTool — Dot-source loadability' {
    It 'Dot-sources without terminating error' {
        { . $script:ScriptPath } | Should -Not -Throw
    }
    It 'Primary function Show-CronAiAthonTool is defined after dot-source' {
        Get-Command 'Show-CronAiAthonTool' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Show-CronAiAthonTool — Nested helper functions (static analysis)' {
    $nestedFunctions = @(
        'New-StyledLabel',
        'New-StyledButton',
        'New-StyledGrid',
        'New-StatusLed',
        'Update-StatusBar',
        'Register-SecretHelpTrigger',
        'Show-SecretHelpPage',
        'New-InnerTab',
        'New-FilterCombo',
        'Load-ViewGrid',
        'Load-AMGrid',
        'Load-ReviewGrid',
        'Update-ReviewItem',
        'Load-EventLogGrid',
        'Load-PipelineSummary',
        'Apply-MasterFilter',
        'Invoke-MasterRefresh',
        'New-StatCard',
        'Refresh-PipelineMonitor',
        'Write-SvcLog'
    )
    It "Contains nested function '<_>'" -ForEach $nestedFunctions {
        $script:Content | Should -Match "function\s+$_\b" -Because 'Nested helper must be defined in the script body'
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




