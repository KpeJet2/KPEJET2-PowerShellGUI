# VersionTag: 2608.B1.V1.0
# SupportPS5.1: YES
# SupportsPS7.6: YES
#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Diagnostic = Join-Path $script:RepoRoot 'scripts\Invoke-GitCommitDiagnostic.ps1'
}

Describe 'Git commit diagnostic Alpha controls' {
    It 'captures baseline regression classification and future permutations' {
        $ws = Join-Path $TestDrive 'git-diagnostic'
        New-Item -ItemType Directory -Path (Join-Path $ws 'scripts') -Force | Out-Null
        Copy-Item -LiteralPath $script:Diagnostic -Destination (Join-Path $ws 'scripts\Invoke-GitCommitDiagnostic.ps1') -Force

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ws 'scripts\Invoke-GitCommitDiagnostic.ps1') `
            -WorkspacePath $ws -Gate 'pipeline-refine' -ExitCode 1 `
            -Message 'Baseline regressions detected: 1' -AlphaSoftFail
        $LASTEXITCODE | Should -Be 0

        $json = @(Get-ChildItem -LiteralPath (Join-Path $ws 'logs\git-errors') -Filter '*.json' -File)[0]
        $record = Get-Content -LiteralPath $json.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $record.classification | Should -Be 'BASELINE_REGRESSION'
        $record.severity | Should -Be 'HIGH'
        @($record.relatedPermutations).Count | Should -BeGreaterThan 3
        $record.alphaSoftFail | Should -BeTrue
        $record.remediation.assessment | Should -Be 'FAIL'
    }

    It 'classifies parser and secret permutations with critical severity' {
        $ws = Join-Path $TestDrive 'git-diagnostic-permutations'
        New-Item -ItemType Directory -Path (Join-Path $ws 'scripts') -Force | Out-Null
        Copy-Item -LiteralPath $script:Diagnostic -Destination (Join-Path $ws 'scripts\Invoke-GitCommitDiagnostic.ps1') -Force

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ws 'scripts\Invoke-GitCommitDiagnostic.ps1') `
            -WorkspacePath $ws -Gate 'pre-commit-validation' -ExitCode 1 `
            -Message 'ParserError: Missing closing brace; secret scanner private key detected' -AlphaSoftFail
        $record = Get-Content -LiteralPath (@(Get-ChildItem -LiteralPath (Join-Path $ws 'logs\git-errors') -Filter '*.json' -File)[0].FullName) -Raw -Encoding UTF8 | ConvertFrom-Json
        $record.classification | Should -Be 'SECRET_GATE_FAILURE'
        $record.severity | Should -Be 'CRITICAL'
    }
}
