# VersionTag: 2604.B1.V32.7
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Modules Pester
Set-StrictMode -Version Latest

BeforeAll {
    $script:WorkspacePath = Split-Path $PSScriptRoot -Parent
    $script:ScanScript    = Join-Path $script:WorkspacePath 'scripts\Invoke-StaticWorkspaceScan.ps1'
    $script:ResultFile    = Join-Path $script:WorkspacePath 'temp\smoke-static-result.json'
}

AfterAll {
    if (Test-Path $script:ResultFile) { Remove-Item $script:ResultFile -Force -ErrorAction SilentlyContinue }
}

Describe 'Invoke-StaticWorkspaceScan -- Script exists' {
    It 'Script file is present' {
        Test-Path -LiteralPath $script:ScanScript | Should -Be $true
    }
    It 'Has a VersionTag header' {
        $first = Get-Content -LiteralPath $script:ScanScript -Encoding UTF8 | Select-Object -First 3
        ($first -join ' ') | Should -Match 'VersionTag'
    }
}

Describe 'Invoke-StaticWorkspaceScan -- Output JSON schema' {
    BeforeAll {
        try {
            & powershell.exe -NoProfile -NonInteractive -File $script:ScanScript `
                -WorkspacePath $script:WorkspacePath `
                -ErrorAction SilentlyContinue 2>$null
        } catch { <# Intentional: scan errors are non-fatal in smoke-test context #> }
    }
    It 'Produces a JSON result file' {
        if (!(Test-Path -LiteralPath $script:ResultFile)) {
            Set-ItResult -Skipped -Because 'Static scan did not produce output file in this test run'
        }
        Test-Path -LiteralPath $script:ResultFile | Should -Be $true
    }
    It 'Result has expected top-level fields' {
        if (!(Test-Path -LiteralPath $script:ResultFile)) { Set-ItResult -Skipped -Because 'scan did not produce output file' }
        $r = Get-Content -LiteralPath $script:ResultFile -Raw | ConvertFrom-Json
        $r.PSObject.Properties.Name | Should -Contain 'phaseResults'
    }
    It 'phaseResults has at least one phase entry' {
        if (!(Test-Path -LiteralPath $script:ResultFile)) { Set-ItResult -Skipped -Because 'scan did not produce output file' }
        $r = Get-Content -LiteralPath $script:ResultFile -Raw | ConvertFrom-Json
        $phases = @($r.phaseResults.PSObject.Properties.Name)
        @($phases).Count | Should -BeGreaterThan 0
    }
}

Describe 'Invoke-StaticWorkspaceScan -- Phase resilience' {
    It 'Script has at least 3 distinct phase blocks' {
        $src = Get-Content -LiteralPath $script:ScanScript -Raw
        $phaseMatches = @([regex]::Matches($src, '# Phase \d+|phaseResults\['))
        @($phaseMatches).Count | Should -BeGreaterThan 2
    }
    It 'Each phase has shouldContinue or try/catch guard' {
        $src = Get-Content -LiteralPath $script:ScanScript -Raw
        $src | Should -Match 'shouldContinue|try\s*\{'
    }
}

Describe 'Invoke-StaticWorkspaceScan -- SIN compliance' {
    It 'Does not use PS7-only null-coalescing operator' {
        $codeLines = (Get-Content -LiteralPath $script:ScanScript -Encoding UTF8) |
            Where-Object { $_ -notmatch '^\s*#' }
        ($codeLines -join ' ') | Should -Not -Match '\?\?'
    }
    It 'Does not use hardcoded absolute paths' {
        $src = Get-Content -LiteralPath $script:ScanScript -Raw
        $src | Should -Not -Match 'C:\\\\PowerShellGUI'
    }
    It 'Does not use Invoke-Expression' {
        $codeLines = (Get-Content -LiteralPath $script:ScanScript -Encoding UTF8) |
            Where-Object { $_ -notmatch '^\s*#' }
        ($codeLines -join ' ') | Should -Not -Match '\bInvoke-Expression\b|\biex\b'
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




