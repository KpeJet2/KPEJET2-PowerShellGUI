# VersionTag: 2605.B5.V46.0
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
<#
.SYNOPSIS  Loadability tests for all Invoke-*.ps1 scripts without existing dedicated test files.
.DESCRIPTION
    Parameterised Pester suite that checks each Invoke-*.ps1 script for:
      - File presence
      - VersionTag header (SIN P007)
      - AST parse with zero errors
      - No PS7-only operators (SIN P005: ??, ?.)
    Excludes scripts that already have dedicated test files:
      Invoke-AgentCallStats, Invoke-EngineCrashCleanup, Invoke-PipelineIntegration (mapped to Integrity),
      Invoke-RegressionSuite, Invoke-StaticWorkspaceScan, Invoke-WidgetSmokeTests.
    Dot-source is omitted for Invoke- scripts because many launch WinForms GUIs
    or interactive blocking loops when invoked — AST parse is the safe loadability gate.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:WsPath = Split-Path $PSScriptRoot -Parent
}

$invokeScripts = @(
    'Invoke-ChecklistActions',
    'Invoke-ConfigCoverageAudit',
    'Invoke-CronProcessor',
    'Invoke-CyclicRenameCheck',
    'Invoke-DataMigration',
    'Invoke-DeduplicationAssessment',
    'Invoke-DependencyScanManager',
    'Invoke-ErrorHandlingContinuousLoop',
    'Invoke-ErrorHandlingRemediation',
    'Invoke-FileChangeTracker',
    'Invoke-FullSystemsScan',
    'Invoke-HistoryRotation',
    'Invoke-ModuleManagement',
    'Invoke-OrphanAudit',
    'Invoke-OrphanCleanup',
    'Invoke-OrphanedFileAudit',
    'Invoke-PipeGAP',
    'Invoke-PSEnvironmentScanner',
    'Invoke-ReferenceIntegrityCheck',
    'Invoke-ReleasePreFlight',
    'Invoke-RenameProposal',
    'Invoke-ReportRetention',
    'Invoke-ScriptDependencyMatrix',
    'Invoke-SelfReviewCycle',
    'Invoke-SINRegistryReindex',
    'Invoke-SINRemedyEngine',
    'Invoke-TestCoverageGateCheck',
    'Invoke-TestRoutine',
    'Invoke-TodoArchiver',
    'Invoke-TodoBundleRebuild',
    'Invoke-TodoManager',
    'Invoke-VersionAlignmentTool',
    'Invoke-WorkspaceDependencyMap',
    'Invoke-WorkspaceRollback',
    'Invoke-XhtmlReportTriage'
)

Describe "Invoke-Script loadability — <_>" -ForEach $invokeScripts {
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

    It 'First line contains VersionTag (SIN P007)' {
        @($script:Lines).Count | Should -BeGreaterThan 0
        $script:Lines[0].Trim() | Should -Match 'VersionTag'
    }

    It 'Parses with zero AST errors' {
        if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
            Set-ItResult -Pending -Because 'File missing'
            return
        }
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$errors
        ) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It 'Contains no PS7-only null-coalescing operator ?? (SIN P005)' {
        if ($null -eq $script:Content) { Set-ItResult -Pending -Because 'File missing'; return }
        $script:Content | Should -Not -Match '(?<!\?)\?\?(?!\?)' -Because 'SIN P005: ?? not valid in PS 5.1'  # SIN-EXEMPT: P005 - false positive: regex/glob literal, not PS7 operator
    }

    It 'Contains no PS7-only null-conditional accessor ?. (SIN P005)' {
        if ($null -eq $script:Content) { Set-ItResult -Pending -Because 'File missing'; return }
        $script:Content | Should -Not -Match '\?\.' -Because 'SIN P005: ?. not valid in PS 5.1'  # SIN-EXEMPT: P005 - false positive: regex/glob literal, not PS7 operator
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





